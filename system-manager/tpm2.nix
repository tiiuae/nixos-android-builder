# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# TPM2 support for system-manager (non-NixOS distributions).
#
# This is a simplified port of the NixOS security.tpm2 module. It manages udev
# rules and environment variables so that keylime (and tpm2-tools in general)
# can talk to the kernel resource manager (/dev/tpmrm0).
#
# Unlike the NixOS module we do NOT:
# - manage kernel modules (the host kernel must have TPM support)
# - ship tpm2-abrmd (Ubuntu provides this via its own packages if needed)
# - configure FAPI (not required for keylime)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.security.tpm2;
in
{
  options.security.tpm2 = {
    enable = lib.mkEnableOption "TPM2 device access and environment";

    tssGroup = lib.mkOption {
      type = lib.types.str;
      default = "tss";
      description = "Group that owns /dev/tpmrm0.";
    };

    tctiEnvironment = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Set TPM2TOOLS_TCTI and TPM2_PKCS11_TCTI so that tpm2-tools and
          keylime use the kernel resource manager by default.
        '';
      };

      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/tpmrm0";
        description = "Device path for the TPM resource manager.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.tssGroup} = { };

    # udev rules: make /dev/tpmrm0 accessible to the tss group.
    # On Ubuntu the tss group and basic rules usually exist already, but we
    # install our own to guarantee the group matches.
    environment.etc."udev/rules.d/99-tpm2-system-manager.rules" = {
      text = ''
        # Created by system-manager tpm2 module
        KERNEL=="tpm[0-9]*",  TAG+="systemd", MODE="0660", OWNER="root"
        KERNEL=="tpmrm[0-9]*", TAG+="systemd", MODE="0660", OWNER="root", GROUP="${cfg.tssGroup}"
      '';
    };

    # Trigger udev reload so the rules take effect without a reboot.
    systemd.services.tpm2-udev-reload = {
      description = "Reload udev rules for TPM devices";
      wantedBy = [ "system-manager.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "tpm2-udev-reload" ''
          ${pkgs.systemdMinimal}/bin/udevadm control --reload-rules
          ${pkgs.systemdMinimal}/bin/udevadm trigger --subsystem-match=tpm  --action=change
          ${pkgs.systemdMinimal}/bin/udevadm trigger --subsystem-match=tpmrm --action=change
        '';
      };
    };

    # Set TCTI environment variables system-wide via /etc/profile.d so that
    # interactive shells and services that source the profile pick them up.
    environment.etc."profile.d/tpm2-tcti.sh" = lib.mkIf cfg.tctiEnvironment.enable {
      text = ''
        export TPM2TOOLS_TCTI="device:${cfg.tctiEnvironment.device}"
        export TPM2_PKCS11_TCTI="device:${cfg.tctiEnvironment.device}"
      '';
    };

    # For systemd services, set the variables globally so they don't need to
    # source /etc/profile.d.
    systemd.globalEnvironment = lib.mkIf cfg.tctiEnvironment.enable {
      TPM2TOOLS_TCTI = "device:${cfg.tctiEnvironment.device}";
      TPM2_PKCS11_TCTI = "device:${cfg.tctiEnvironment.device}";
    };
  };
}
