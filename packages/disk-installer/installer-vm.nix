# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.virtualisation.vmVariant.virtualisation;
  hostPkgs = cfg.host.pkgs;
  disk-installer = hostPkgs.callPackage ./. { };
in
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  options.diskInstaller.vmInstallerTarget = lib.mkOption {
    type = lib.types.str;
    default = "select";
    internal = true;
  };

  options.diskInstaller.vmStorageTarget = lib.mkOption {
    type = lib.types.str;
    default = "select";
    internal = true;
  };

  config = {
    boot.initrd.systemd.initrdBin = [
      # machine.get_tty_text requries awk
      pkgs.gawk
      # grep is required by the initrd backdoor
      pkgs.gnugrep
    ];

    virtualisation = {
      cores = 8;
      memorySize = 1024 * 8;
      directBoot.enable = false;
      installBootLoader = false;
      useBootLoader = true;
      useEFIBoot = true;
      mountHostNixStore = false;
      efi.keepVariables = false;
      tpm.enable = true;

      # OVMF with TPM2 firmware support.  Secure boot is not enabled
      # here (tested separately in the desktop VM test).  OVMFFull
      # breaks the installer test because the installed UKI is unsigned.
      efi.OVMF = hostPkgs.OVMF.override { tpmSupport = true; };

      # NixOS overrides filesystems for VMs by default
      fileSystems = lib.mkForce { };
      useDefaultFilesystems = false;

      emptyDiskImages = [
        (1024 * 300)
        # second image for artifact storage if enabled
        (1024 * 10)
      ];
    };

    system.build.prepareInstallerDisk = hostPkgs.writeShellApplication {
      name = "prepare-installer-disk";
      text = ''
          if [ ! -e ${cfg.diskImage} ]; then
            echo >&2 "Copying ${config.system.build.image}/${config.image.fileName} to ${cfg.diskImage}"
            ${cfg.qemu.package}/bin/qemu-img convert \
              -f raw -O raw \
              "${config.system.build.image}/${config.image.fileName}" \
              "${cfg.diskImage}"

            echo >&2 "Preparing ${cfg.diskImage}"
            ${lib.getExe disk-installer.configure} set-target --target "${config.diskInstaller.vmInstallerTarget}" --device "${cfg.diskImage}"
            ${lib.optionalString (config.diskInstaller.vmStorageTarget != "select") ''
              ${lib.getExe disk-installer.configure} set-storage --target "${config.diskInstaller.vmStorageTarget}" --device "${cfg.diskImage}"
            ''}
          else
            echo "${cfg.diskImage} already exists, skipping creation & signing"
        fi
      '';
    };

    system.build.vmWithInstallerDisk = hostPkgs.writeShellApplication {
      name = "run-${config.system.name}-vm";
      text = ''
        ${lib.getExe config.system.build.prepareInstallerDisk}
        ${lib.getExe config.system.build.vm} "$@"
      '';
    };
  };
}
