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
  # piv-multiparty requires one card per configured group.
  requiredKeys = builtins.length config.security.pam.multiparty.groups;

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
    echo "Insert all ${toString requiredKeys} YubiKey(s), then touch each one when prompted and enter its PIN."
    login user
    systemctl poweroff
  '';

  # Pre-build escape hatch: gives the operator 30s to insert *all*
  # YubiKeys before the unattended pipeline starts. We only hand off
  # to `login` once we see one YubiKey USB device per configured group,
  # because piv-multiparty requires co-presence and a partial set would
  # fail auth — burning the operator's only chance to log in before the
  # build.
  start-shell-if-yubikey-found = pkgs.writeShellScriptBin "start-shell-if-yubikey-found" ''
    set -euo pipefail
    ELAPSED=0
    echo "Insert all ${toString requiredKeys} YubiKey(s) in the next 30 seconds to start interactive shell"
    while [ $ELAPSED -lt 30 ]; do
      yk_count=$(lsusb | grep -ic 'yubikey' || true)
      if [ "$yk_count" -ge ${toString requiredKeys} ]; then
        tput sgr0
        tput ed
        echo "Found $yk_count YubiKey(s). Touch each one when prompted and enter its PIN."
        exec login user
      fi
      sleep 1
      ELAPSED=$((ELAPSED + 1))
    done
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
      start-shell-if-yubikey-found
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
