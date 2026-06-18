# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Store outputs on an unencrypted, persistent disk partition
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.nixosAndroidBuilder.artifactStorage;
  copyAndroidOutputs = pkgs.writeShellScriptBin "copy-android-outputs" ''
    set -e

    SOURCE_DIR='${config.nixosAndroidBuilder.build.sourceDir}'
    ARTIFACT_DIR="${cfg.artifactDir}"

    find_expr=()
    while IFS= read -r pattern; do
      [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
      find_expr+=(-path "./$pattern" -o)
    done < /etc/artifacts

    # Remove trailing -o
    [ ''${#find_expr[@]} -gt 0 ] && unset 'find_expr[-1]'

    (
      cd "$SOURCE_DIR/out"
      echo -e "\nCopying output artifacts to $ARTIFACT_DIR\n\n"
      find . -type f \( "''${find_expr[@]}" \) 2>/dev/null | \
        rsync -av --files-from=- . "$ARTIFACT_DIR/$(date +%Y-%m-%d-%H:%M:%S)/"
    )
  '';

in
{
  options.nixosAndroidBuilder.artifactStorage = {
    enable = lib.mkEnableOption "Storing outputs in an unencrypted, persistent disk partition";
    diskLabel = lib.mkOption {
      description = "disk label that identifies the storage partition";
      type = lib.types.str;
      default = "artifacts";
    };

    contents = lib.mkOption {
      description = "list of files (or patterns) to copy from build outputs";
      type = lib.types.listOf lib.types.str;
      default = [
        "*"
      ];
    };

    artifactDir = lib.mkOption {
      description = ''
        Directory where the persistent artifact storage is mounted.
      '';
      type = lib.types.path;
      default = "/var/lib/artifacts";

    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.artifactDir} 0755 user user - -"
    ];
    environment.etc."artifacts".text = "${lib.join "\n" cfg.contents}\n";
    environment.systemPackages = [ copyAndroidOutputs ];

    fileSystems."${cfg.artifactDir}" = {
      device = "/dev/disk/by-label/${cfg.diskLabel}";
      fsType = "ext4";
    };

    boot.initrd.systemd = {
      units."dev-disk-by\\x2dlabeli-artifacts.device.d/timeout.conf" = {
        text = ''
            [Unit]
          JobTimeoutSec=Infinity
        '';
      };

      extraBin = {
        lsblk = "${pkgs.util-linux}/bin/lsblk";
        blkid = "${pkgs.util-linux}/bin/blkid";
        tee = "${pkgs.coreutils}/bin/tee";
        jq = "${pkgs.jq}/bin/jq";
        dialog = "${pkgs.dialog}/bin/dialog";
        systemd-cat = "${pkgs.systemdMinimal}/bin/systemd-cat";
        chvt = "${pkgs.kbd}/bin/chvt";
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

      services = {
        prepare-artifact-storage = {
          description = "Prepare unencrypted, persistent output storage";

          after = [
            "boot.mount"
            "systemd-udev-settle.service"
          ];
          before = [
            "initrd-switch-root.service"
          ];
          wantedBy = [
            "initrd-switch-root.target"
            "initrd.target"
            "rescue.target"
          ];
          requiredBy = [
            "initrd-switch-root.target"
            "initrd.target"
            "rescue.target"
          ];

          unitConfig = {
            DefaultDependencies = false;
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
          onFailure = [ "emergency.target" ];

          environment = {
            DISK_LABEL = cfg.diskLabel;
          };

          script = builtins.readFile ./artifact-storage.sh;
        };
      };
    };
  };
}
