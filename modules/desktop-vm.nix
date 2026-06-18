# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# VM settings for the desktop configuration.
#
# Provides system.build.vmWithWritableDisk which can be exposed as
# `nix run .#run-desktop-vm`.
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
      diskSize = 100 * 1024;
      memorySize = 8 * 1024;
      cores = 4;

      useSecureBoot = true;
      tpm.enable = true;

      directBoot.enable = false;
      installBootLoader = false;
      useBootLoader = true;
      useEFIBoot = true;
      mountHostNixStore = false;
      efi.OVMF = hostPkgs.OVMFFull;
      efi.keepVariables = false;

      # Don't let the VM module add its own default filesystems.
      # Mirror image.nix's filesystems here because qemu-vm.nix
      # overrides fileSystems with virtualisation.fileSystems.
      useDefaultFilesystems = false;
      fileSystems = lib.mkForce {
        "/" = {
          device = "/dev/disk/by-partlabel/root";
          fsType = "ext4";
        };
        "/boot" = {
          device = "/dev/disk/by-partlabel/boot";
          fsType = "vfat";
        };
      };

      graphics = true;

      diskImage = config.image.fileName;
    };

    # Secure boot test keys, cached in the nix store.
    system.build.secureBootKeysForTests = hostPkgs.runCommandLocal "test-keys" { } ''
      ${lib.getExe secureBootScripts.create-signing-keys} $out/
    '';

    # Prepare a writable copy of the image and sign the UKI for secure boot.
    system.build.prepareWritableDisk = hostPkgs.writeShellApplication {
      name = "prepare-writable-disk";
      text = ''
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

          echo >&2 "Signing UKI in ${cfg.diskImage}"
          ${lib.getExe disk-installer.configure} sign \
            --keystore "${config.system.build.secureBootKeysForTests}" \
            --device "${cfg.diskImage}"
        else
          echo "${cfg.diskImage} already exists, skipping creation & signing"
        fi
      '';
    };

    # Wrapper: prepare disk, then launch VM.
    system.build.vmWithWritableDisk = hostPkgs.writeShellApplication {
      name = "run-${config.system.name}-vm";
      text = ''
        ${lib.getExe config.system.build.prepareWritableDisk}
        ${lib.getExe config.system.build.vm} "$@"
      '';
    };
  };
}
