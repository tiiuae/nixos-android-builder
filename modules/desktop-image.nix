# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Disk image and partition layout for the desktop configuration.
#
# Simple conventional layout:
#   - ESP with UKI (secure boot signed)
#   - ext4 root partition with the full NixOS system
#   - systemd-repart grows root to fill disk at first boot
{
  pkgs,
  lib,
  config,
  ...
}:
let
  efiArch = config.nixpkgs.hostPlatform.efiArch;
  efiUki = "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI";
in
{
  config = {
    system.image = {
      id = config.system.name;
      version = config.system.nixos.version;
    };

    # Standard filesystem layout.
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-partlabel/root";
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/disk/by-partlabel/boot";
        fsType = "vfat";
      };
    };

    ## Build-time image configuration (systemd-repart)
    image.repart = {
      # OVMF does not work with the default repart sector size of 4096
      sectorSize = 512;
      name = config.system.name;

      partitions = {
        "00-esp" = {
          contents = {
            "${efiUki}".source = "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
            "/image-id".source = pkgs.writeText "image-id" "${config.system.name}\n";
          };
          repartConfig = {
            Type = "esp";
            Label = "boot";
            Format = "vfat";
            SizeMinBytes = "256M";
          };
        };
        "10-root" = {
          storePaths = [ config.system.build.toplevel ];
          repartConfig = {
            Type = "root";
            Label = "root";
            Format = "ext4";
            Minimize = "guess";
          };
        };
      };
    };

    # Grow root partition to fill disk at first boot.
    boot.initrd.systemd.repart.enable = true;
    systemd.repart.partitions."10-root" = {
      Type = "root";
      Label = "root";
      GrowFileSystem = true;
    };

    # Copy a read-only snapshot of the flake into the user's home on
    # first boot. Only applied when self is passed via _module.args
    # (real image builds); skipped in tests where it is not provided.
    systemd.tmpfiles.rules =
      let
        self = config._module.args.self or null;
      in
      lib.optional (self != null) "C /home/user/nixos-android-builder 0755 user user - ${self}";
  };
}
