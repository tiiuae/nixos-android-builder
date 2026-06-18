# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  config,
  lib,
  pkgs,
  customPackages,
  ...
}:

let
  cfg = config.services.keylime;
  inherit (customPackages) keylime;
  shared = import ./lib/keylime-shared.nix { inherit lib pkgs keylime; };
in
{
  options.services.keylime = shared.mkOptions keylime;

  config = lib.mkMerge [
    (shared.mkTlsConfig cfg)
    (lib.mkIf cfg.enable {
      security.tpm2 = {
        enable = true;
        tctiEnvironment.enable = true;
      };

      users.users.keylime = {
        isSystemUser = true;
        group = "keylime";
        home = "/var/lib/keylime";
      };

      users.groups.keylime = { };

      systemd.tmpfiles.rules = [
        "d /var/lib/keylime 0750 keylime keylime -"
      ]
      ++ shared.mkTmpfilesRules cfg;

      environment.systemPackages = [ cfg.package ];
      environment.etc = shared.mkEtcFiles cfg;

      systemd.services = shared.mkServices {
        inherit cfg;
        wantedBy = [ "multi-user.target" ];
      };

      networking.firewall.allowedTCPPorts = shared.mkFirewallPorts cfg;
    })
  ];
}
