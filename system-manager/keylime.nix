# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Keylime server (registrar + verifier) module for system-manager.
#
# Shares options, defaults, and config generation with modules/keylime.nix
# via keylime-shared.nix. Adds TLS auto-generation and uses
# system-manager.target instead of multi-user.target.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.keylime;
  tlsCfg = cfg.tls;
  shared = import ../modules/lib/keylime-shared.nix { inherit lib pkgs; };
  keylimePkg = cfg.package;

  tlsDir = "/var/lib/keylime/tls";
  caCert = "${tlsDir}/ca-cert.pem";
  caKey = "${tlsDir}/ca-key.pem";
  serverCert = "${tlsDir}/server-cert.pem";
  serverKey = "${tlsDir}/server-key.pem";
  clientCert = "${tlsDir}/client-cert.pem";
  clientKey = "${tlsDir}/client-key.pem";

in
{
  options.services.keylime = shared.mkOptions (pkgs.callPackage ../packages/keylime { });

  config = lib.mkMerge [
    (shared.mkTlsConfig cfg)
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ keylimePkg ];

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
        "d ${tlsDir} 0750 keylime keylime -"
      ]
      ++ shared.mkTmpfilesRules cfg;

      environment.etc = shared.mkEtcFiles cfg;

      systemd.services = shared.mkServices {
        inherit cfg;
        wantedBy = [ "system-manager.target" ];
      };
    })
  ];
}
