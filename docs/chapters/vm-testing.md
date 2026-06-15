# Virtual Machine Testing {#sec-vm-testing}

Test the full setup in QEMU. Requires KVM (enable VT-x/AMD-V in firmware; verify with `lsmod | grep kvm`).

## Builder VM

```bash
nix run .#run-vm
```

Creates a writable image copy, signs it with test keys, and starts QEMU with Secure Boot and TPM. If `attestation-server.json` is present in the current directory, the keylime agent is configured from it (same format as `/boot/attestation-server.json`, see @sec-agent-config).

Subsequent runs reuse the existing `.raw` file. Delete it to start from a clean image.

## Installer VM

```bash
nix run .#installer-vm
```

Tests the @sec-disk-installer workflow in a VM.

## Exiting

```bash
systemctl poweroff   # from within the VM
```

Or close the QEMU window.
