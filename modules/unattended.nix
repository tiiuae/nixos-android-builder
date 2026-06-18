# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.nixosAndroidBuilder.unattended;
  user = config.users.users.user;

  disable-usb-guard = pkgs.writeShellScriptBin "disable-usb-guard" ''
    set -euo pipefail
    systemctl stop usbguard
    for device in /sys/bus/usb/devices/*/authorized; do
      echo 1 > "$device" 2>/dev/null
    done
    for host in /sys/bus/usb/devices/usb*/authorized_default; do
      echo 1 > "$host"
    done
  '';

  lock-var-lib-build = pkgs.writeShellScriptBin "lock-var-lib-build" ''
    set -euo pipefail

    umount -v /var/lib/build
    luksDevice="$(cryptsetup status var_lib_crypt | awk '/device:/ {print $2}')"
    cryptsetup close var_lib_crypt
    cryptsetup luksKillSlot --batch-mode $luksDevice 0

    # Verify that the disk encryption key has been removed
    luksKeyslots="$(cryptsetup luksDump $luksDevice --dump-json-metadata | jq '.keyslots | length')"
    if [ $luksKeyslots = "0" ]; then
      echo "disk encryption key deleted"
    else
      echo "not all keys were deleted, there's still $luksKeyslots keys in use" | tee /run/fatal-error
      exit 1
    fi
  '';

  start-shell-and-shutdown = pkgs.writeShellScriptBin "start-shell-and-shutdown" ''
    set -euo pipefail
    tput sgr0
    tput ed
    echo "NOTE: The system will turn off after exiting this shell"
    echo "Build outputs are in /var/lib/artifacts"
    echo "Please touch your YubiKey to authenticate..."
    login user
    systemctl poweroff
  '';
in
{
  options.nixosAndroidBuilder.unattended = {
    enable = lib.mkEnableOption "unattended mode";

    steps = lib.mkOption {
      description = "list of shell commands to run unattended ";
      default = [
        "root:start-shell-if-yubikey-found"
        "select-branch"
        "fetch-android"
        "build-android"
        "android-sbom"
        "android-measure-source"
        "copy-android-outputs"
        "root:lock-var-lib-build"
        "root:disable-usb-guard"
        "root:start-shell-and-shutdown"
      ];
      type = lib.types.listOf lib.types.str;
    };
  };

  config = lib.mkIf cfg.enable {
    security.loginDefs.settings.LOGIN_TIMEOUT = 0;
    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
      execWheelOnly = true;
    };

    environment.systemPackages = [
      pkgs.jq
      pkgs.usbutils
      disable-usb-guard
      lock-var-lib-build
      start-shell-and-shutdown
    ];

    # disable gettty on tty1 and 2 (logins on tty)
    systemd.services."autovt@tty1".enable = false;
    systemd.services."autovt@tty2".enable = false;

    # USBGuard: block mass storage devices (class 08) to prevent
    # unauthorized data exfiltration during builds. Everything else
    # is allowed — keyboard, mouse, YubiKey, network adapters, etc.
    # This is an intentional trade-off: the build machine needs these
    # USB devices for operation, and the build environment is
    # air-gapped (no network connectivity required). The
    # disable-usb-guard script stops USBGuard near the end of the
    # build pipeline to allow copying artifacts to USB storage.
    services.usbguard = {
      enable = true;
      rules = ''
        # Block all mass storage devices (class 08)
        block with-interface equals { 08:*:* }
        # Allow everything else
        allow
      '';
    };

    systemd.services.nixos-android-builder = {
      description = "NixOS Android Builder";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        User = user.name;
        Group = user.group;
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty2";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        Restart = "no";
      };
      onFailure = [ "emergency.target" ];

      environment = {
        PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin:/bin";
        HOME = user.home;
        STEPS = lib.concatStringsSep "," cfg.steps;
        TERM = "linux";
      };

      script = builtins.readFile ./unattended.sh;

    };
  };
}
