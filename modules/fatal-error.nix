# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib, pkgs, ... }:

let
  targets = {
    emergency = {
      wants = [ "fatal-error.service" ];
    };
  };
  services = {
    # We want to display our error, not panic
    panic-on-fail.enable = lib.mkForce false;

    # Upstreams emergency.service would grab the whole tty in case
    # emergencyAccess is enabled.
    emergency = {
      serviceConfig = {
        ExecStartPre = lib.mkForce [ "" ];
        ExecStart = lib.mkForce [
          ""
          "${pkgs.coreutils}/bin/true"
        ];
        StandardInput = lib.mkForce "null";
        StandardOutput = lib.mkForce "null";
      };
    };

    fatal-error = {
      description = "Display a fatal error to the user";

      after = [ "systemd-udevd.service" ];
      requires = [ "systemd-udevd.service" ];
      unitConfig = {
        DefaultDependencies = "no";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty2";
        TTYReset = true;
        Restart = "no";
      };

      environment = {
        TERM = "linux";
        TERMINFO = "${pkgs.ncurses}/share/terminfo";
      };

      path = [
        pkgs.coreutils
        pkgs.dialog
        pkgs.kbd
        pkgs.systemd
      ];

      script = ''
        chvt 2

        # Without those udevadm commands, we might not yet have keyboard input
        # if we entered the emergency target too early
        udevadm trigger --action=add
        udevadm settle --timeout=10
        dialog \
            --clear \
            --colors \
            --ok-button " Shutdown " \
            --title "Error" \
            --msgbox "$(cat /run/fatal-error || echo "Unknown error, please consult logs (ctrl+alt+f1)")" \
            10 60
        chvt 1
        systemctl --no-block poweroff
      '';
    };
  };
in
{
  boot.initrd.systemd = {
    inherit targets services;
    # dialog links against libncurses, but the terminfo data directory is not
    # a library dependency and won't be pulled into the initrd automatically.
    # Add it explicitly so the TERMINFO env var in fatal-error.service resolves.
    storePaths = [ pkgs.ncurses ];
    extraBin = {
      cat = "${pkgs.coreutils}/bin/cat";
      dialog = "${pkgs.dialog}/bin/dialog";
      chvt = "${pkgs.kbd}/bin/chvt";
    };
  };
  systemd = {
    inherit targets services;
  };
  environment.systemPackages = [
    pkgs.dialog
    pkgs.kbd
  ];
}
