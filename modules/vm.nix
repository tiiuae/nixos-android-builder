# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Settings which should only be applied if run as a VM, not on bare metal.
{
  lib,
  config,
  ...
}:
let
  cfg = config.virtualisation;
  hostPkgs = cfg.host.pkgs;

  secureBootScripts = hostPkgs.callPackage ../packages/secure-boot-scripts { };
  disk-installer = hostPkgs.callPackage ../packages/disk-installer { };
in
{
  config = {
    virtualisation = {
      diskSize = 300 * 1024;
      memorySize = 64 * 1024;
      cores = 32;

      useSecureBoot = true;
      tpm.enable = true;

      # Don't use direct boot for the VM to verify that the bootloader is working.
      directBoot.enable = false;
      installBootLoader = false;
      useBootLoader = true;
      useEFIBoot = true;
      mountHostNixStore = false;
      efi.OVMF = hostPkgs.OVMFFull;
      efi.keepVariables = false;

      # NixOS overrides filesystems for VMs by default
      fileSystems = lib.mkForce { };
      useDefaultFilesystems = false;

      # Start a headless VM with serial console.
      graphics = true;

      # Use a raw image, not image for the vm (for easier post-processing with mtools & such).
      diskImage = config.image.fileName;

      emptyDiskImages = lib.optionals config.nixosAndroidBuilder.artifactStorage.enable [
        (1024 * 10)
      ];
    };

    # Create a set of private keys for VM tests, but cache them in the /nix/store,
    # so we don't need to create a new pair on each run.
    system.build.secureBootKeysForTests = hostPkgs.runCommandLocal "test-keys" { } ''
      ${lib.getExe secureBootScripts.create-signing-keys} $out/
    '';

    # Helper that copies the read-only image out of the nix store, to a
    # writable copy in $PWD. It then signs an UKI inside the images ESP and
    # copies SecureBoot keys to it.
    system.build.prepareWritableDisk = hostPkgs.writeShellApplication {
      name = "prepare-writable-disk";
      text =
        let
          cfg = config.virtualisation;
        in
        ''
            if [ ! -e ${cfg.diskImage} ]; then

              echo >&2 "Copying ${config.system.build.image}/${config.image.fileName} to ${cfg.diskImage}"
              ${cfg.qemu.package}/bin/qemu-img convert \
                -f raw -O raw \
                "${config.system.build.image}/${config.image.fileName}" \
                "${cfg.diskImage}"

              echo >&2 "Resizing ${cfg.diskImage} to ${toString cfg.diskSize}M"
              ${cfg.qemu.package}/bin/qemu-img resize \
                "${cfg.diskImage}" \
                "${toString cfg.diskSize}M"

              echo >&2 "Preparing ${cfg.diskImage}"
              ${lib.getExe disk-installer.configure} sign \
                --keystore "${config.system.build.secureBootKeysForTests}" \
                --device "${cfg.diskImage}"

              ${lib.getExe disk-installer.configure} set-storage \
                --target "/dev/vdb" \
                --device "${cfg.diskImage}"

              # Configure attestation server from local attestation-server.json
              # (same format as /boot/attestation-server.json).
              if [ -f attestation-server.json ]; then
                echo >&2 "Configuring attestation server from ./attestation-server.json"
                jq=${hostPkgs.jq}/bin/jq
                ca_cert=$(mktemp)
                $jq -r '.ca_cert' attestation-server.json > "$ca_cert"
                ${lib.getExe disk-installer.configure} set-attestation-server \
                  --ip "$($jq -r '.ip' attestation-server.json)" \
                  --ca-cert "$ca_cert" \
                  --device "${cfg.diskImage}"
                rm -f "$ca_cert"
              fi

            else
              echo "${cfg.diskImage} already exists, skipping creation & signing"
          fi
        '';
    };

    # Upstreams system.build.vm wrapped to prepare a writeable & signed image
    # before starting the vm.
    system.build.vmWithWritableDisk = hostPkgs.writeShellApplication {
      name = "run-${config.system.name}-vm";
      text = ''
        ${lib.getExe config.system.build.prepareWritableDisk}
        ${lib.getExe config.system.build.vm} "$@"
      '';
    };
  };
}
