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
  disk-installer = pkgs.callPackage ./. { };
  cfg = config.diskInstaller;
in
{

  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  options.diskInstaller = {
    debug = (lib.mkEnableOption "verbose logging and a debug shell") // {
      default = true;
    };

    payload = lib.mkOption {
      description = "file to write to disk";
      type = lib.types.str;
    };
  };

  config = {
    system.stateVersion = "25.11";
    system.name = "disk-installer";

    # noop settings to appease nixos modules system
    boot.loader.grub.enable = false;
    fileSystems = {
      "/" = {
        device = "none";
        fsType = "tmpfs";
      };
    };

    boot.initrd.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "vfat"
      "nls_cp437"
      "nls_iso8859-1"

      "uhci_hcd"
      "ehci_hcd"
      "xhci_hcd"
      "xhci_pci"

      "usb_storage"
      "uas"
      "usbhid"
      "thunderbolt"
      "nvme"

      "sd_mod"
      "sr_mod"

      "vfat"
      "nls_cp437"
      "nls_iso8859_1"
    ];

    boot.kernelParams = [
      "systemd.show_status=true"
      "systemd.log_level=info"
      "systemd.log_target=console"
      "console=tty1"
    ]
    ++ (lib.optionals cfg.debug [
      "rd.systemd.debug_shell=tty3"
    ]);

    image.repart = {

      mkfsOptions.erofs = [
        "-zlz4"
        "-Efragments,ztailpacking"
      ];
      sectorSize = 512;
      name = config.system.name;

      partitions = {
        "00-esp" =
          let
            efiArch = config.nixpkgs.hostPlatform.efiArch;
            efiUki = "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI";
          in
          {
            contents = {
              "${efiUki}".source = "${config.system.build.uki}/nixos.efi";
            };
            repartConfig = {
              Type = "esp";
              Label = "disk-installer";
              Format = "vfat";
              SizeMinBytes = "128M";
            };
          };
        "10-payload".repartConfig = {
          Type = "linux-generic";
          Label = "payload";
          CopyBlocks = cfg.payload;
        };
      };
    };

    boot.initrd.systemd = {
      emergencyAccess = cfg.debug;

      enable = true;

      initrdBin = [
        pkgs.gptfdisk
        pkgs.dosfstools
        disk-installer.run
      ];
      extraBin = {
        lsblk = "${pkgs.util-linux}/bin/lsblk";
        tee = "${pkgs.coreutils}/bin/tee";
        jq = "${pkgs.jq}/bin/jq";
        ddrescue = "${pkgs.ddrescue}/bin/ddrescue";
        dialog = "${pkgs.dialog}/bin/dialog";
        systemd-cat = "${pkgs.systemdMinimal}/bin/systemd-cat";
        chvt = "${pkgs.kbd}/bin/chvt";
        fgconsole = "${pkgs.kbd}/bin/fgconsole";
      };

      mounts =
        let
          esp = config.image.repart.partitions."00-esp".repartConfig;
        in
        [
          {
            where = "/boot";
            what = "/dev/disk/by-partlabel/${esp.Label}";
            type = esp.Format;
            unitConfig = {
              DefaultDependencies = false;
            };
            requiredBy = [ "initrd-fs.target" ];
            before = [ "initrd-fs.target" ];
          }
        ];

      targets.initrd-switch-root.enable = true;
      services = {
        initrd-switch-root.enable = true;
        initrd-cleanup.enable = true;
        initrd-parse-etc.enable = false;
        initrd-nixos-activation.enable = false;
        initrd-find-nixos-closure.enable = false;

        disk-installer = {
          description = "Early user prompt during initrd";

          after = [
            "boot.mount"
          ];
          wantedBy = [ "initrd.target" ];

          unitConfig = {
            DefaultDependencies = false;
          };

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardInput = "tty-force";
            TTYVHangup = true;
            StandardOutput = "tty";
            StandardError = "tty";
            TTYPath = "/dev/tty2";
            TTYReset = true;
            Restart = "no";
          };

          onFailure = [ "emergency.target" ];

          environment = {
            INSTALL_SOURCE = "/dev/disk/by-partlabel/payload";
          };
          script = lib.getExe disk-installer.run;
        };
      };
    };
  };
}
