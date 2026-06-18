# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# To test yubikey auth in the vm, get your yubikeys product ids and then run:
# nix run -L .\#run-vm -- -usb -device usb-host,vendorid=0x1050,productid=0x0407 -device usb-host,vendorid=0x1050,productid=0x0116
{
  pkgs,
  lib,
  config,
  ...
}:
let
  hasGroupA = config.nixosAndroidBuilder.yubikeys.groupA != [ ];
  hasGroupB = config.nixosAndroidBuilder.yubikeys.groupB != [ ];

  u2fOrigin = "pam://nixos-android-builder";

  # Shared PAM stack for services that authenticate via U2F only.
  # Used by greetd, login, and su.
  mkU2fPamText = ''
    # Account management.
    account required ${pkgs.pam}/lib/security/pam_unix.so

    # Authentication management.
    auth required ${pkgs.pam_u2f}/lib/security/pam_u2f.so authfile=/etc/u2f_mappings_groupA origin=${u2fOrigin} appid=${u2fOrigin}
    ${lib.optionalString hasGroupB "auth required ${pkgs.pam_u2f}/lib/security/pam_u2f.so authfile=/etc/u2f_mappings_groupB origin=${u2fOrigin} appid=${u2fOrigin}"}

    # Session management.
    session required ${pkgs.pam}/lib/security/pam_env.so conffile=/etc/pam/environment readenv=0
    session required ${pkgs.pam}/lib/security/pam_unix.so
    session required ${pkgs.pam}/lib/security/pam_loginuid.so
    session optional ${config.systemd.package}/lib/security/pam_systemd.so
  '';
in
{
  options.nixosAndroidBuilder.yubikeys.groupA = lib.mkOption {
    description = ''
      list of u2f (i.e. yubikeys) public keys for pam, as output by pamu2fcfg

      pamu2fcfg -N -i "pam://nixos-android-builder" -o "pam://nixos-android-builder" -u "user"
    '';
    type = lib.types.listOf lib.types.str;
  };

  options.nixosAndroidBuilder.yubikeys.groupB = lib.mkOption {
    description = ''
      list of u2f (i.e. yubikeys) public keys for pam, as output by pamu2fcfg

      pamu2fcfg -N -i "pam://nixos-android-builder" -o "pam://nixos-android-builder" -u "user"
    '';
    type = lib.types.listOf lib.types.str;
  };

  config = {
    environment.etc.u2f_mappings_groupA.text = lib.concatStringsSep "\n" config.nixosAndroidBuilder.yubikeys.groupA;
    environment.etc.u2f_mappings_groupB.text = lib.concatStringsSep "\n" config.nixosAndroidBuilder.yubikeys.groupB;

    environment.systemPackages = [
      pkgs.usbutils
      (pkgs.writeShellScriptBin "start-shell-if-yubikey-found" ''
        set -euo pipefail
        ELAPSED=0
        echo "Insert a Yubikey in the next 30 seconds to start interactive shell"
        while [ $ELAPSED -lt 30 ]; do
          if lsusb | grep -qi 'yubikey'; then
            tput sgr0
            tput ed
            echo "Found. Please touch your YubiKey to authenticate..."
            exec login user
          fi
          sleep 1
          ELAPSED=$((ELAPSED + 1))
        done
      '')
    ];

    security.pam.u2f = lib.mkIf hasGroupA {
      enable = true;
      control = "required";
      settings = {
        authfile = "/etc/u2f_mappings_groupA";
        origin = u2fOrigin;
        appid = u2fOrigin;
      };
    };

    # When U2F keys are configured, all interactive PAM services use
    # U2F-only auth (no password). When no keys are configured, leave
    # PAM defaults intact so the system remains accessible.
    security.pam.services.greetd = lib.mkIf hasGroupA {
      text = mkU2fPamText;
    };

    security.pam.services.login = lib.mkIf hasGroupA {
      text = mkU2fPamText;
    };

    security.pam.services.su = lib.mkIf hasGroupA {
      text = mkU2fPamText;
    };

    # Allow passwordless login only when U2F keys are configured
    # (U2F replaces password auth). Without keys, this would create
    # unauthenticated access paths.
    users.allowNoPasswordLogin = hasGroupA;

    # When no U2F keys are configured, provide an empty initial password
    # so the NixOS "locked out" assertion passes. The user must set a
    # real password or configure U2F keys before production use.
    users.users.user.initialHashedPassword = lib.mkIf (!hasGroupA) "";
  };
}
