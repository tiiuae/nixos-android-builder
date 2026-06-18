# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Generic NixOS base configuration shared across all machine types.
{
  lib,
  pkgs,
  ...
}:
{

  imports = [
    ./nix.nix
  ];

  config = {
    # All users must be declared at build-time.
    users.mutableUsers = false;

    # Configure a build user
    users = {
      users."user" = {
        isNormalUser = true;
        group = "user";
        extraGroups = [
          "kvm"
          "wheel"
        ];
        home = "/home/user";
        createHome = true;
      };
      groups.user = { };
    };

    # Opt-in into systemd-based initrd, declarative user management and networking.
    boot.initrd.systemd.enable = true;
    services.userborn.enable = true;
    networking.useNetworkd = true;

    # Add all available firmware.
    hardware.enableRedistributableFirmware = true;
    hardware.enableAllHardware = true;

    # Console font with full Unicode box-drawing support (U+2500-U+257F).
    # systemd puts the console in UTF-8 mode at boot; the kernel then maps
    # Unicode code points through the font's Unicode table.  The default
    # VGA ROM font has no entries for U+2500+, so those glyphs render as '?'.
    console = {
      font = "ter-v32n";
      packages = [ pkgs.terminus_font ];
      earlySetup = true;
    };

    # Console on tty1 for bare-metal
    boot.consoleLogLevel = lib.mkForce 3;
    boot.kernelParams = [
      "systemd.log_target=console"
      "systemd.log_level=err"
      "console=tty1"
    ]
    ++ (lib.optional (
      pkgs.stdenv.hostPlatform.isAarch32 || pkgs.stdenv.hostPlatform.isAarch64
    ) "console=ttyAMA0,115200");

    # Ensure kernel modules for various storage backends are enabled in initrd
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

    # Define a stateVersion to suppress eval warnings. As we don't keep state, it's irrelevant.
    system.stateVersion = "25.05";
  };
}
