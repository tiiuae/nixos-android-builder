#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# flake8: noqa: E501
import sys
import os
import json
import subprocess
import tempfile
import argparse
from pathlib import Path


UUID_EFI_SYSTEM = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
UUID_LINUX_FILESYSTEM = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
SECTOR_SIZE = 512


class InstallerError(Exception):
    """Base exception for installer tool errors."""
    pass


def get_partition_offset(device, type_uuid):
    """Get the byte offset of a partition by its type UUID."""
    try:
        result = subprocess.run(
            ["sfdisk", "-J", str(device)],
            capture_output=True, text=True, check=True
        )
        layout = json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        raise InstallerError("Cannot read partition table") from e

    partition = next((p for p in layout.get("partitiontable", {}).get("partitions", [])
                     if p.get("type") == type_uuid), None)
    if not partition or partition.get("start") is None:
        raise InstallerError(f"Cannot find partition of type {type_uuid}")

    sector_size = layout.get("partitiontable", {}).get("sectorsize")
    if not sector_size == SECTOR_SIZE:
        raise InstallerError(f"Sector size of {device} does not match SECTOR_SIZE {SECTOR_SIZE}")
    return partition["start"] * sector_size


def get_image_id(img_spec):
    """Read /image-id from an ESP to identify the image type (e.g. 'android-builder', 'desktop')."""
    result = subprocess.run(
        ["mtype", "-i", img_spec, "::/image-id"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def get_payload_image_id(device):
    """Get the image-id from the payload's ESP (works for both payload-only and installer images)."""
    payload_only = is_payload_only(device)
    if payload_only:
        esp_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
    else:
        esp_offset = get_payload_esp_offset(device)
    return get_image_id(f"{device}@@{esp_offset}")


def require_builder_image(device, command):
    """Raise an error if the image is not an android-builder image."""
    image_id = get_payload_image_id(device)
    if image_id and image_id != "android-builder":
        raise InstallerError(
            f"The '{command}' command is only supported for android-builder images "
            f"(this image is '{image_id}')")


def is_payload_only(device):
    """Check if this is a payload-only image (no nested installer structure)."""
    try:
        installer_offset = get_partition_offset(device, UUID_LINUX_FILESYSTEM)
    except InstallerError:
        # No Linux filesystem partition means this is payload-only
        return True

    # Check if there's a valid nested GPT
    gpt_entry_offset = installer_offset + 1024 + 32
    try:
        with open(device, "rb") as f:
            f.seek(gpt_entry_offset)
            data = f.read(8)
            payload_start = int.from_bytes(data, byteorder='little') if len(data) == 8 else 0
    except (IOError, OSError):
        return True

    return not payload_start


def get_payload_esp_offset(device):
    """Get the byte offset of the nested ESP partition in the payload."""
    installer_offset = get_partition_offset(device, UUID_LINUX_FILESYSTEM)
    gpt_entry_offset = installer_offset + 1024 + 32

    try:
        with open(device, "rb") as f:
            f.seek(gpt_entry_offset)
            data = f.read(8)
            payload_start = int.from_bytes(data, byteorder='little') if len(data) == 8 else 0
    except (IOError, OSError) as e:
        raise InstallerError(f"Cannot read device: {e}") from e

    if not payload_start:
        raise InstallerError("Cannot parse GPT partition table")

    return installer_offset + payload_start * SECTOR_SIZE


def get_keystore(args):
    """Get keystore path from args or environment variable."""
    keystore = Path(args.keystore) if args.keystore else (
        Path(os.environ['KEYSTORE']) if 'KEYSTORE' in os.environ else None)
    if not keystore:
        raise InstallerError("Keystore must be provided via --keystore flag or KEYSTORE environment variable")
    return keystore


def verify_mtools_access(img_spec):
    """Check if mtools can access the filesystem."""
    result = subprocess.run(
        ["mdir", "-i", img_spec, "::"],
        capture_output=True, check=False
    )
    return result.returncode == 0


def verify_signature(efi_path, cert_path):
    """Verify the signature of an EFI file."""
    result = subprocess.run(
        ["sbverify", "--cert", str(cert_path), str(efi_path)],
        check=False, capture_output=True
    )
    return result.returncode == 0


def extract_and_verify_uki(img_spec, cert_path, label):
    """Extract UKI from image and verify signature."""
    with tempfile.NamedTemporaryFile(suffix=".efi", delete=False) as temp_efi:
        temp_path = Path(temp_efi.name)

    try:
        result = subprocess.run(
            ["mcopy", "-n", "-i", img_spec, "::/EFI/BOOT/BOOTX64.EFI", str(temp_path)],
            check=False, capture_output=True
        )

        if result.returncode == 0:
            status = "✓ Signed and verified" if verify_signature(temp_path, cert_path) else "✗ Not signed or verification failed"
        else:
            status = "✗ Could not extract UKI"

        print(f"{label} Secure Boot status:")
        print(f"  {status}\n")
    finally:
        temp_path.unlink(missing_ok=True)


def copy_secureboot_keys(img_spec, keystore):
    """Copy PK.auth, KEK.auth, and db.auth from keystore to ESP/KEYS directory for secure boot auto enrollment"""
    print(f"Copying keystore files for auto-enrollment...")


    subprocess.run(
        ["mmd", "-i", img_spec, "-D", "s", "::/KEYS"],
        check=False, capture_output=True
    )

    keystore_files = ["PK.auth", "KEK.auth", "db.auth"]

    for filename in keystore_files:
        src_file = keystore / filename
        if not src_file.exists():
            raise InstallerError(f"Missing {filename} in keystore")

        result = subprocess.run(
            ["mcopy", "-n", "-o", "-i", img_spec, str(src_file), f"::/KEYS/{filename}"],
            check=False, capture_output=True
        )
        if result.returncode != 0:
            raise InstallerError(f"Failed to copy {filename} to ESP")
    print(f"✓ Keystore files copied to ESP")


def sign_uki(device, img_spec, key_path, cert_path, label):
    """Extract, sign, and write back a UKI."""
    if not verify_mtools_access(img_spec):
        raise InstallerError(f"Cannot access {label.lower()} EFI partition (invalid FAT filesystem)")

    with tempfile.NamedTemporaryFile(suffix=".efi", delete=False) as temp_efi:
        temp_path = Path(temp_efi.name)

    try:
        print(f"Extracting {label.lower()} UKI...")
        if subprocess.run(
            ["mcopy", "-n", "-i", img_spec, "::/EFI/BOOT/BOOTX64.EFI", str(temp_path)],
            check=False, capture_output=True
        ).returncode != 0:
            raise InstallerError(f"Failed to extract {label.lower()} UKI")

        print(f"Signing {label.lower()} UKI with Secure Boot key...")
        if subprocess.run(
            ["sbsign", "--key", str(key_path), "--cert", str(cert_path),
             "--output", str(temp_path), str(temp_path)],
            check=False, capture_output=True
        ).returncode != 0:
            raise InstallerError(f"Failed to sign {label.lower()} UKI")

        print(f"Writing signed {label.lower()} UKI back...")
        if subprocess.run(
            ["mcopy", "-n", "-o", "-i", img_spec, str(temp_path), "::/EFI/BOOT/BOOTX64.EFI"],
            check=False, capture_output=True
        ).returncode != 0:
            raise InstallerError(f"Failed to write {label.lower()} UKI")

        print(f"✓ {label} UKI signed successfully")
    finally:
        temp_path.unlink(missing_ok=True)


def show_install_target(img_spec):
    print("Installation target:")
    result = subprocess.run(
        ["mdir", "-i", img_spec, "::/install_target"],
        capture_output=True, check=False,
    )
    interactive_msg = 'Interactive menu (user will select target)'
    if result.returncode == 0:
        target = subprocess.run(
            ["mtype", "-i", img_spec, "::/install_target"],
            capture_output=True, text=True
        ).stdout.strip().replace('\r', '').replace('\n', '')
        print(f"  {interactive_msg if target == 'select' else f'Automatic installation to: {target}'}")
    else:
        print(f"  {interactive_msg}")
    print()


def show_storage_target(img_spec):
    print("Storage target:")
    result = subprocess.run(
        ["mdir", "-i", img_spec, "::/storage_target"],
        capture_output=True, check=False,
    )
    if result.returncode == 0:
        target = subprocess.run(
            ["mtype", "-i", img_spec, "::/storage_target"],
            capture_output=True, text=True
        ).stdout.strip().replace('\r', '').replace('\n', '')
        print(f"  Automatic provisioning of storage on: {target}")
    else:
        print(f"  Interactive menu (user will select artifact storage)")
    print()



def cmd_status(args):
    """Check status of installer image."""
    device = Path(args.device)
    if not device.exists():
        raise InstallerError(f"Device or image file not found: {device}")

    keystore = get_keystore(args)
    if not keystore.is_dir():
        raise InstallerError(f"Keystore directory not found: {keystore}")

    cert_path = keystore / "db.crt"
    if not cert_path.is_file():
        raise InstallerError("Missing db.crt in keystore")

    payload_only = is_payload_only(device)

    if payload_only:
        # Payload-only image: outer EFI partition is the payload
        print("Image type: Payload-only (no installer)\n")

        esp_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
        esp_img_spec = f"{device}@@{esp_offset}"

        if not verify_mtools_access(esp_img_spec):
            raise InstallerError("Cannot access EFI partition (invalid FAT filesystem)")

        image_id = get_image_id(esp_img_spec)
        if image_id:
            print(f"Image ID: {image_id}\n")

        if not image_id or image_id == "android-builder":
            show_storage_target(esp_img_spec)
            show_attestation_server_status(esp_img_spec)
        extract_and_verify_uki(esp_img_spec, cert_path, "Payload")
    else:
        # Full installer image with nested payload
        print("Image type: Installer with nested payload\n")

        installer_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
        installer_img_spec = f"{device}@@{installer_offset}"

        if not verify_mtools_access(installer_img_spec):
            raise InstallerError("Cannot access EFI partition (invalid FAT filesystem)")

        payload_offset = get_payload_esp_offset(device)
        payload_img_spec = f"{device}@@{payload_offset}"

        if not verify_mtools_access(payload_img_spec):
            raise InstallerError("Cannot access nested EFI partition (invalid FAT filesystem)")

        image_id = get_image_id(payload_img_spec)
        if image_id:
            print(f"Payload image ID: {image_id}\n")

        show_install_target(installer_img_spec)
        if not image_id or image_id == "android-builder":
            show_storage_target(installer_img_spec)
            show_attestation_server_status(payload_img_spec)

        extract_and_verify_uki(installer_img_spec, cert_path, "Installer")
        extract_and_verify_uki(payload_img_spec, cert_path, "Payload")



def cmd_sign(args):
    """Sign UKI for Secure Boot."""
    keystore = get_keystore(args)
    device = Path(args.device)

    if not device.exists():
        raise InstallerError(f"Device or image file not found: {device}")
    if not keystore.is_dir():
        raise InstallerError(f"Keystore directory not found: {keystore}")

    key_path = keystore / "db.key"
    cert_path = keystore / "db.crt"

    if not key_path.is_file() or not cert_path.is_file():
        raise InstallerError("Missing db.key or db.crt in keystore")

    payload_only = is_payload_only(device)
    sign_installer = (not payload_only) and (args.installer or (not args.payload and not args.installer))
    sign_payload = args.payload or (not args.payload and not args.installer)

    if payload_only:
        # Payload-only image
        if sign_installer:
            raise InstallerError("Cannot sign installer: this is a payload-only image (no installer present)")

        if sign_payload:
            payload_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
            sign_uki(device, f"{device}@@{payload_offset}", key_path, cert_path, "Payload")
            if args.auto_enroll:
                copy_secureboot_keys(f"{device}@@{payload_offset}", keystore)

    else:
        # Full installer image
        if sign_installer:
            installer_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
            sign_uki(device, f"{device}@@{installer_offset}", key_path, cert_path, "Installer")

        if sign_payload:
            payload_offset = get_payload_esp_offset(device)
            sign_uki(device, f"{device}@@{payload_offset}", key_path, cert_path, "Payload")
            if args.auto_enroll:
                copy_secureboot_keys(f"{device}@@{payload_offset}", keystore)



def cmd_set_target(args):
    """Configure installation target."""
    device = Path(args.device)
    if not device.exists():
        raise InstallerError(f"Device or image file not found: {device}")

    payload_only = is_payload_only(device)

    # For both payload-only and installer images, modify the outer EFI partition
    esp_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
    esp_img_spec = f"{device}@@{esp_offset}"

    if not verify_mtools_access(esp_img_spec):
        raise InstallerError("Cannot access EFI partition (invalid FAT filesystem)")

    with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_target:
        temp_target.write(args.target)
        temp_path = Path(temp_target.name)

    try:
        if subprocess.run(
            ["mcopy", "-n", "-o", "-i", esp_img_spec, str(temp_path), "::/install_target"],
            check=False, capture_output=True
        ).returncode != 0:
            raise InstallerError("Failed to write install target")

        image_type = "payload-only image" if payload_only else "installer image"
        if args.target == "select":
            print(f"✓ Configured {image_type} for interactive installation\n  User will select target disk during boot")
        else:
            print(f"✓ Configured {image_type} for automatic installation\n  Will install to: {args.target}")
    finally:
        temp_path.unlink(missing_ok=True)


def cmd_set_storage(args):
    """Configure target for artifact storage."""
    require_builder_image(args.device, "set-storage")
    device = Path(args.device)
    if not device.exists():
        raise InstallerError(f"Device or image file not found: {device}")

    payload_only = is_payload_only(device)

    if payload_only:
        # Payload-only image: outer EFI partition is the payload
        print("Image type: Payload-only (no installer)\n")

        esp_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
        esp_img_spec = f"{device}@@{esp_offset}"

        if not verify_mtools_access(esp_img_spec):
            raise InstallerError("Cannot access EFI partition (invalid FAT filesystem)")
    else:
        # Full installer image with nested payload
        print("Image type: Installer with nested payload\n")

        installer_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
        installer_img_spec = f"{device}@@{installer_offset}"

        if not verify_mtools_access(installer_img_spec):
            raise InstallerError("Cannot access EFI partition (invalid FAT filesystem)")

        esp_offset = get_payload_esp_offset(device)
        esp_img_spec = f"{device}@@{esp_offset}"

        if not verify_mtools_access(esp_img_spec):
            raise InstallerError("Cannot access nested EFI partition (invalid FAT filesystem)")

    with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_target:
        temp_target.write(args.target)
        temp_path = Path(temp_target.name)

    try:
        if args.target == "select":
            subprocess.run(
                ["mdel", "-i", esp_img_spec, "::/storage_target"],
                check=False, capture_output=True)
            print(f"✓ Configured for interactive menu\nUser will select artifact storage target disk during boot")
        else:
            if subprocess.run(
                ["mcopy", "-n", "-o", "-i", esp_img_spec, str(temp_path), "::/storage_target"],
                check=False, capture_output=True
            ).returncode != 0:
                raise InstallerError("Failed to write storage target")
            print(f"✓ Configured for automatic provisioning\n  Will provision artifact storage on: {args.target}")
    finally:
        temp_path.unlink(missing_ok=True)


def show_attestation_server_status(img_spec):
    result = subprocess.run(
        ["mtype", "-i", img_spec, "::/attestation-server.json"],
        capture_output=True, text=True, check=False,
    )
    print("Attestation server:")
    if result.returncode == 0:
        try:
            data = json.loads(result.stdout)
            ip = data.get("ip", "?")
            port = data.get("port", 8891)
            verifier_port = data.get("verifier_port", 8881)
            has_cert = "ca_cert" in data and data["ca_cert"]
            print(f"  ✓ Server: {ip} (registrar:{port}, verifier:{verifier_port})")
            print(f"  ✓ CA cert: {'present' if has_cert else 'MISSING'}")
        except json.JSONDecodeError:
            print("  ✗ attestation-server.json exists but is not valid JSON")
    else:
        print("  ✗ Not configured (run: configure-disk-image set-attestation-server --ip <server> --ca-cert <pem> --device <image>)")
    print()


def cmd_set_attestation_server(args):
    """Write attestation-server.json to the ESP for runtime keylime agent configuration."""
    require_builder_image(args.device, "set-attestation-server")
    device = Path(args.device)
    if not device.exists():
        raise InstallerError(f"Device or image file not found: {device}")

    ca_cert_path = Path(args.ca_cert)
    if not ca_cert_path.is_file():
        raise InstallerError(f"CA certificate file not found: {ca_cert_path}")

    ca_cert_pem = ca_cert_path.read_text()

    payload_only = is_payload_only(device)
    if payload_only:
        esp_offset = get_partition_offset(device, UUID_EFI_SYSTEM)
    else:
        esp_offset = get_payload_esp_offset(device)

    esp_img_spec = f"{device}@@{esp_offset}"
    if not verify_mtools_access(esp_img_spec):
        raise InstallerError("Cannot access EFI partition")

    server_data = {
        "ip": args.ip,
        "ca_cert": ca_cert_pem,
    }
    if args.port != 8891:
        server_data["port"] = args.port
    if args.verifier_port != 8881:
        server_data["verifier_port"] = args.verifier_port

    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(server_data, f, indent=2)
        temp_path = Path(f.name)

    try:
        if subprocess.run(
            ["mcopy", "-n", "-o", "-i", esp_img_spec,
             str(temp_path), "::/attestation-server.json"],
            check=False, capture_output=True
        ).returncode != 0:
            raise InstallerError("Failed to write attestation-server.json to ESP")
    finally:
        temp_path.unlink(missing_ok=True)

    print(f"✓ Attestation server configured on ESP:")
    print(f"  Server: {args.ip} (registrar:{args.port}, verifier:{args.verifier_port})")
    print(f"  CA cert: {ca_cert_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage installer disk images",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables:
    KEYSTORE    Default keystore directory (can be overridden with --keystore)

Examples:
    %(prog)s status --device installer.raw --keystore ./keystore
    %(prog)s sign --device installer.raw --payload
    %(prog)s sign --device installer.raw --payload --no-auto-enroll
    %(prog)s set-target --device installer.raw --target select
    %(prog)s set-storage --device installer.raw --target /dev/vdc
        """
    )

    subparsers = parser.add_subparsers(dest='command', required=True)

    status_parser = subparsers.add_parser('status', help='Check status of installer image')
    status_parser.add_argument('--device', required=True, help='Block device or disk image file')
    status_parser.add_argument('--keystore', help='Directory containing db.crt (overrides KEYSTORE env var)')

    sign_parser = subparsers.add_parser('sign', help='Sign UKI for Secure Boot')
    sign_parser.add_argument('--keystore', help='Directory containing db.key and db.crt (overrides KEYSTORE env var)')
    sign_parser.add_argument('--device', required=True, help='Block device or disk image file')
    sign_parser.add_argument('--installer', action='store_true', help='Sign only installer UKI')
    sign_parser.add_argument('--payload', action='store_true', help='Sign only payload UKI')
    sign_parser.add_argument('--auto-enroll', action=argparse.BooleanOptionalAction, default=True,
                           help='Copy keystore files (PK.auth, KEK.auth, db.auth) to ESP for auto-enrollment (default: enabled)')


    target_parser = subparsers.add_parser('set-target', help='Configure installation target')
    target_parser.add_argument('--target', required=True, help='Target device (e.g., /dev/sda) or "select" for interactive')
    target_parser.add_argument('--device', required=True, help='Block device or disk image file')

    storage_parser = subparsers.add_parser('set-storage', help='Configure target for build artifact storage')
    storage_parser.add_argument('--target', required=True, help='Target device (e.g., /dev/sda) or "select" for interactive')
    storage_parser.add_argument('--device', required=True, help='Block device or disk image file')

    registrar_parser = subparsers.add_parser('set-attestation-server', help='Configure keylime registrar/verifier connection on ESP')
    registrar_parser.add_argument('--ip', required=True, help='Registrar/verifier server IP address')
    registrar_parser.add_argument('--ca-cert', required=True, help='Path to CA certificate PEM file')
    registrar_parser.add_argument('--port', type=int, default=8891, help='Registrar TLS port (default: 8891)')
    registrar_parser.add_argument('--verifier-port', type=int, default=8881, help='Verifier port (default: 8881)')
    registrar_parser.add_argument('--device', required=True, help='Block device or disk image file')

    args = parser.parse_args()

    try:
        {
            'status': cmd_status,
            'sign': cmd_sign,
            'set-target': cmd_set_target,
            'set-storage': cmd_set_storage,
            'set-attestation-server': cmd_set_attestation_server,
        }[args.command](args)
    except InstallerError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
