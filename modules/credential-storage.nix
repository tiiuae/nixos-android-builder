# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Store systemd credentials on a persistent, TPM2-bound LUKS partition
#
# This module bind-mounts the credential directory to
# /run/credstore.encrypted/ so systemd services can load encrypted
# credentials from persistent storage.
#
# Credentials should be encrypted with `systemd-creds encrypt` using the
# machine's TPM.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.nixosAndroidBuilder.credentialStorage;
in
{
  options.nixosAndroidBuilder.credentialStorage = {
    enable = lib.mkEnableOption "persistent credential storage on a TPM2-bound LUKS partition";

    encryptionFlags = lib.mkOption {
      description = "Flags to pass to systemd-creds encrypt. See man (1) systemd-creds";
      type = lib.types.listOf lib.types.str;
      default = [
        "--with-key=tpm2"
        "--tpm2-pcrs=7"
      ];
    };

    credentialDir = lib.mkOption {
      description = ''
        Directory where credentials are stored.
        This is the mount point of the dedicated credentials partition
        and will be bind-mounted to /run/credstore.encrypted/
      '';
      type = lib.types.path;
      default = "/var/lib/credentials";
    };

    mountPoint = lib.mkOption {
      description = ''
        Where to mount the credential directory.
        /run/credstore.encrypted/ is automatically searched by systemd for encrypted credentials
      '';
      type = lib.types.path;
      default = "/run/credstore.encrypted";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.credentialDir} 0700 root root - -"
    ];

    fileSystems."${cfg.mountPoint}" = {
      device = cfg.credentialDir;
      fsType = "none";
      options = [ "bind" ];
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "io.systemd.credentials.encrypt" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "credential-store" ''
        set -euo pipefail

        CRED_DIR="${cfg.credentialDir}"

        usage() {
          cat >/dev/stderr <<EOF
        Usage: $0 <command> [args]

        Commands:
          list                     List stored credentials
          add <name> [file]        Add a credential (reads from stdin if no file given)
          remove <name>            Remove a credential
          show <name>              Show credential contents

        Credentials are stored in: $CRED_DIR
        EOF
          exit 1
        }

        validate_name() {
          if ! [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            echo "Invalid credential name: '$1'" >/dev/stderr
            echo "Names must start with a letter or digit and may only contain letters, digits, dots, hyphens, and underscores." >/dev/stderr
            exit 1
          fi
        }

        case "''${1:-}" in
          list)
            ls -1 "$CRED_DIR" 2>/dev/null || echo "No credentials stored" >/dev/stderr
            ;;
          add)
            name="''${2:-}"
            file="''${3:-}"
            [ -z "$name" ] && usage
            validate_name "$name"
            if [ -n "$file" ]; then
              systemd-creds encrypt ${lib.concatStringsSep " " cfg.encryptionFlags} "$file" "$CRED_DIR/$name"
            else
              systemd-creds encrypt ${lib.concatStringsSep " " cfg.encryptionFlags} - "$CRED_DIR/$name"
            fi
            chmod 600 "$CRED_DIR/$name"
            ;;
          remove)
            name="''${2:-}"
            [ -z "$name" ] && usage
            validate_name "$name"
            rm -f "$CRED_DIR/$name"
            ;;
          show)
            name="''${2:-}"
            [ -z "$name" ] && usage
            validate_name "$name"
            systemd-creds decrypt "$CRED_DIR/$name" -
            ;;
          *)
            usage
            ;;
        esac
      '')
    ];
  };
}
