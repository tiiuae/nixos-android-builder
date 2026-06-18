# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Shared definitions for the keylime server NixOS module (modules/keylime.nix)
# and the system-manager port (system-manager/keylime.nix). Contains INI
# helpers, config defaults, option declarations, and config-file generators.
{
  lib,
  pkgs,
  keylime ? pkgs.callPackage ../../packages/keylime { },
}:

let
  measuredBootPolicy = pkgs.callPackage ../../packages/keylime-measured-boot-policy {
    inherit keylime;
  };

  # Keylime's config.getlist() uses ast.literal_eval and expects Python list
  # literals (e.g. '["value"]') for certain options.
  mkValueString =
    v:
    if builtins.isList v then
      "[${lib.concatMapStringsSep ", " (s: ''"${s}"'') v}]"
    else if builtins.isBool v then
      (if v then "True" else "False")
    else if builtins.isInt v then
      toString v
    else if builtins.isString v then
      v
    else
      throw "unsupported INI value type: ${builtins.typeOf v}";

  toINI = lib.generators.toINI {
    mkKeyValue = lib.generators.mkKeyValueDefault { inherit mkValueString; } " = ";
  };
in
rec {
  inherit toINI;

  keylimeEtc = name: text: {
    ${name} = {
      inherit text;
      user = "keylime";
      group = "keylime";
      mode = "0440";
    };
  };

  settingsType = lib.types.attrsOf (
    lib.types.oneOf [
      lib.types.str
      lib.types.int
      lib.types.bool
      (lib.types.listOf lib.types.str)
      (lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
          (lib.types.listOf lib.types.str)
        ]
      ))
    ]
  );

  commonServiceConfig = {
    User = "keylime";
    Group = "keylime";
    Restart = "on-failure";
    RestartSec = "10s";
    TimeoutSec = "60s";
    StateDirectory = "keylime";
    StateDirectoryMode = "0750";
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/keylime" ];
    PrivateTmp = true;
    NoNewPrivileges = true;
  };

  registrarDefaults = {
    version = "2.5";
    ip = "0.0.0.0";
    port = 8890;
    tls_port = 8891;
    tls_dir = "default";
    server_key = "default";
    server_key_password = "";
    server_cert = "default";
    cert_subject_alternative_names = "";
    trusted_client_ca = "default";
    authorization_provider = "simple";
    database_url = "sqlite";
    database_pool_sz_ovfl = "5,10";
    auto_migrate_db = true;
    durable_attestation_import = "";
    persistent_store_url = "";
    transparency_log_url = "";
    time_stamp_authority_url = "";
    time_stamp_authority_certs_path = "";
    persistent_store_format = "json";
    persistent_store_encoding = "";
    transparency_log_sign_algo = "sha256";
    signed_attributes = "ek_tpm,aik_tpm,ekcert";
    tpm_identity = "default";
    malformed_cert_action = "warn";
  };

  tenantDefaults = {
    version = "2.5";
    registrar_ip = "127.0.0.1";
    registrar_port = 8891;
    verifier_ip = "127.0.0.1";
    verifier_port = 8881;
    tls_dir = "default";
    client_key = "default";
    client_cert = "default";
    trusted_server_ca = "default";
    max_retries = 5;
    retry_interval = 2;
    accept_tpm_hash_algs = ''["sha512", "sha384", "sha256"]'';
    accept_tpm_encryption_algs = ''["ecc", "rsa"]'';
    accept_tpm_signing_algs = ''["ecschnorr", "rsassa"]'';
    require_ek_cert = false;
  };

  verifierDefaults = {
    version = "2.5";
    uuid = "default";
    ip = "0.0.0.0";
    port = 8881;
    registrar_ip = "127.0.0.1";
    registrar_port = 8891;
    enable_agent_mtls = true;
    tls_dir = "generate";
    server_key = "default";
    server_key_password = "";
    server_cert = "default";
    cert_subject_alternative_names = "";
    trusted_client_ca = "default";
    client_key = "default";
    client_key_password = "";
    client_cert = "default";
    trusted_server_ca = "default";
    authorization_provider = "simple";
    database_url = "sqlite";
    database_pool_sz_ovfl = "5,10";
    auto_migrate_db = true;
    num_workers = 0;
    exponential_backoff = true;
    retry_interval = 2;
    max_retries = 5;
    request_timeout = "60.0";
    quote_interval = 2;
    max_upload_size = 104857600;
    measured_boot_policy_name = "uki";
    measured_boot_imports = ''["measured_boot_policy"]'';
    measured_boot_evaluate = "always";
    severity_labels = ''["info", "notice", "warning", "error", "critical", "alert", "emergency"]'';
    severity_policy = ''[{"event_id": ".*", "severity_label" : "emergency"}]'';
    ignore_tomtou_errors = false;
    durable_attestation_import = "";
    persistent_store_url = "";
    transparency_log_url = "";
    time_stamp_authority_url = "";
    time_stamp_authority_certs_path = "";
    persistent_store_format = "json";
    persistent_store_encoding = "";
    transparency_log_sign_algo = "sha256";
    signed_attributes = "";
    require_allow_list_signatures = false;
    mode = "push";
    challenge_lifetime = 1800;
    verification_timeout = 0;
    session_create_rate_limit_per_ip = 50;
    session_create_rate_limit_window_ip = 60;
    session_create_rate_limit_per_agent = 15;
    session_create_rate_limit_window_agent = 60;
    session_lifetime = 180;
    extend_token_on_attestation = true;
  };

  revocationDefaults = {
    enabled_revocation_notifications = "[agent]";
    zmq_ip = "127.0.0.1";
    zmq_port = 8992;
    webhook_url = "";
  };

  mkCaConf = toINI {
    ca = {
      version = "2.5";
      password = "default";
      cert_country = "US";
      cert_ca_name = "Keylime Certificate Authority";
      cert_state = "MA";
      cert_locality = "Lexington";
      cert_organization = "MITLL";
      cert_org_unit = "53";
      cert_ca_lifetime = 3650;
      cert_lifetime = 365;
      cert_bits = 2048;
      cert_crl_dist = "http://localhost:38080/crl";
    };
  };

  mkLoggingConf =
    cfg:
    let
      # Convert a Python logger qualname (e.g. "keylime.web") to a safe INI
      # section identifier (e.g. "keylime_web") for fileConfig's [logger_*] sections.
      qualNameToId = name: builtins.replaceStrings [ "." ] [ "_" ] name;

      overrideNames = builtins.attrNames cfg.logLevelOverrides;
      overrideIds = map qualNameToId overrideNames;

      loggerKeys = [
        "root"
        "keylime"
      ]
      ++ overrideIds;

      overrideSections = lib.listToAttrs (
        map (name: {
          name = "logger_${qualNameToId name}";
          value = {
            level = cfg.logLevelOverrides.${name};
            qualname = name;
            handlers = "";
          };
        }) overrideNames
      );
    in
    toINI (
      {
        logging.version = "2.5";
        loggers.keys = lib.concatStringsSep "," loggerKeys;
        handlers.keys = "consoleHandler";
        formatters.keys = "formatter";
        formatter_formatter = {
          format = "%(asctime)s.%(msecs)03d - %(name)s - %(levelname)s - %(message)s";
          datefmt = "%Y-%m-%d %H:%M:%S";
        };
        logger_root = {
          level = cfg.logLevel;
          handlers = "consoleHandler";
        };
        handler_consoleHandler = {
          class = "StreamHandler";
          level = cfg.logLevel;
          formatter = "formatter";
          args = "(sys.stdout,)";
        };
        logger_keylime = {
          level = cfg.logLevel;
          qualname = "keylime";
          handlers = "";
        };
      }
      // overrideSections
    );

  mkRegistrarConf =
    cfg:
    toINI {
      registrar = registrarDefaults // cfg.registrar.settings;
    };

  mkTenantConf =
    cfg:
    toINI {
      tenant = tenantDefaults // cfg.tenant.settings;
    };

  mkVerifierConf =
    cfg:
    let
      userSettings = builtins.removeAttrs cfg.verifier.settings [ "revocations" ];
    in
    toINI {
      verifier = verifierDefaults // userSettings;
      revocations = revocationDefaults // (cfg.verifier.settings.revocations or { });
    };

  mkOptions = keylimePkg: {
    enable = lib.mkEnableOption "Keylime TPM-based remote attestation server";

    package = lib.mkOption {
      type = lib.types.package;
      default = keylimePkg;
      description = "The keylime package to use.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "DEBUG"
        "INFO"
        "WARNING"
        "ERROR"
        "CRITICAL"
      ];
      default = "INFO";
      description = "Log level for keylime services.";
    };

    logLevelOverrides = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "DEBUG"
          "INFO"
          "WARNING"
          "ERROR"
          "CRITICAL"
        ]
      );
      default = {
        "keylime.web" = "WARNING";
        "keylime.authorization.manager" = "WARNING";
      };
      description = ''
        Per-logger log level overrides. Keys are Python logger qualnames
        (e.g. `keylime.web`), values are log levels.

        By default, the noisy `keylime.web` and
        `keylime.authorization.manager` loggers are set to WARNING to
        suppress routine per-request INFO messages. Set to `{ }` to
        restore the previous behaviour.
      '';
    };

    measuredBootPolicyPath = lib.mkOption {
      type = lib.types.path;
      default = measuredBootPolicy.policyPath;
      description = ''
        Directory containing the measured boot policy Python module.
        Added to the verifier's PYTHONPATH. The module must register
        a policy name matching `measured_boot_policy_name` in
        verifier.conf.
      '';
    };

    registrar = {
      enable = lib.mkEnableOption "Keylime registrar service";
      settings = lib.mkOption {
        type = settingsType;
        default = { };
        description = "Settings for registrar.conf [registrar] section.";
      };
    };

    verifier = {
      enable = lib.mkEnableOption "Keylime verifier service";
      settings = lib.mkOption {
        type = settingsType;
        default = { };
        description = ''
          Settings for verifier.conf. A nested `revocations` attrset maps to
          the [revocations] INI section.
        '';
      };
    };

    tenant = {
      settings = lib.mkOption {
        type = settingsType;
        default = { };
        description = "Settings for tenant.conf [tenant] section.";
      };
    };

    tls = {
      autoGenerate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Automatically generate a self-signed CA and mTLS certificates
          in `/var/lib/keylime/tls/` on first activation.  Existing
          certificates are never overwritten.
        '';
      };

      certLifetime = lib.mkOption {
        type = lib.types.int;
        default = 365;
        description = "Validity period in days for generated certificates.";
      };

      subjectAlternativeNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "DNS:keylime.example.com"
          "IP:10.0.0.1"
        ];
        description = ''
          Additional Subject Alternative Names for the server certificate.
          Host IPs are auto-discovered; use this for extra DNS names or IPs.
        '';
      };
    };

    autoEnroll = {
      enable = lib.mkEnableOption "automatic enrollment of new Keylime agents with measured boot policy";

      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Seconds between polling the registrar for new agents.";
      };

      enrollPort = lib.mkOption {
        type = lib.types.port;
        default = 8893;
        description = "HTTPS port for the measured boot report endpoint.";
      };
    };

    gitServer = {
      enable = lib.mkEnableOption "attestation-gated git HTTP server";

      port = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "HTTPS port nginx listens on for git clone requests.";
      };

      authPort = lib.mkOption {
        type = lib.types.port;
        default = 8895;
        description = ''
          Localhost port for the attestation auth subrequest backend.
          Only reachable from nginx on the same host.
        '';
      };

      repoDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/keylime-git/repos";
        description = ''
          Directory containing bare git repositories served to attested agents.
        '';
      };

      repos = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "config"
          "firmware"
        ];
        description = ''
          Bare git repositories to create on first boot (without the
          .git suffix).
        '';
      };
    };

  };

  # When tls.autoGenerate is enabled, return config attrset that sets
  # mkDefault TLS paths for registrar, verifier, and tenant.
  # Apply with: config = lib.mkMerge [ ... (shared.mkTlsConfig cfg) ];
  mkTlsConfig =
    cfg:
    let
      tlsDir = "/var/lib/keylime/tls";
      caCert = "${tlsDir}/ca-cert.pem";
      serverCert = "${tlsDir}/server-cert.pem";
      serverKey = "${tlsDir}/server-key.pem";
      clientCert = "${tlsDir}/client-cert.pem";
      clientKey = "${tlsDir}/client-key.pem";
    in
    lib.mkIf cfg.tls.autoGenerate {
      services.keylime.registrar.settings = lib.mkIf cfg.registrar.enable {
        tls_dir = lib.mkDefault tlsDir;
        server_key = lib.mkDefault serverKey;
        server_cert = lib.mkDefault serverCert;
        trusted_client_ca = lib.mkDefault [ caCert ];
      };
      services.keylime.tenant.settings = {
        tls_dir = lib.mkDefault tlsDir;
        client_key = lib.mkDefault clientKey;
        client_cert = lib.mkDefault clientCert;
        trusted_server_ca = lib.mkDefault [ caCert ];
      };
      services.keylime.verifier.settings = lib.mkIf cfg.verifier.enable {
        tls_dir = lib.mkDefault tlsDir;
        server_key = lib.mkDefault serverKey;
        server_cert = lib.mkDefault serverCert;
        trusted_client_ca = lib.mkDefault [ caCert ];
        client_key = lib.mkDefault clientKey;
        client_cert = lib.mkDefault clientCert;
        trusted_server_ca = lib.mkDefault [ caCert ];
      };
    };

  # Auto-enroll daemon — same script used by system-manager and NixOS.
  autoEnrollScript = pkgs.writers.writePython3 "keylime-auto-enroll" {
    flakeIgnore = [
      "E501"
      "E266"
      "N802"
    ];
  } (builtins.readFile ./scripts/keylime-auto-enroll.py);

  # Cert generation script shared between system-manager and NixOS VM tests.
  generateCertsScript = pkgs.writers.writePython3 "keylime-generate-certs" {
    libraries = [ ];
  } (builtins.readFile ./scripts/keylime-generate-certs.py);

  mkEtcFiles =
    cfg:
    keylimeEtc "keylime/ca.conf" mkCaConf
    // keylimeEtc "keylime/logging.conf" (mkLoggingConf cfg)
    // keylimeEtc "keylime/tenant.conf" (mkTenantConf cfg)
    // lib.optionalAttrs cfg.registrar.enable (
      keylimeEtc "keylime/registrar.conf" (mkRegistrarConf cfg)
    )
    // lib.optionalAttrs cfg.verifier.enable (keylimeEtc "keylime/verifier.conf" (mkVerifierConf cfg))
    // lib.optionalAttrs cfg.gitServer.enable {
      "keylime-git/nginx.conf" = {
        text = mkGitNginxConf { inherit cfg; };
        mode = "0444";
      };
      "keylime-git/hooks/post-receive" = {
        text = gitPostReceiveHook;
        mode = "0555";
      };
    };

  mkServices =
    {
      cfg,
      wantedBy,
      extraAfter ? { },
    }:
    let
      tlsDir = "/var/lib/keylime/tls";
      tlsAfter = lib.optional cfg.tls.autoGenerate "keylime-tls.service";
      git = cfg.gitServer;
    in
    # TLS cert generation
    lib.optionalAttrs cfg.tls.autoGenerate {
      keylime-tls = mkTlsService {
        inherit tlsDir wantedBy;
        certDays = cfg.tls.certLifetime;
        extraSans = cfg.tls.subjectAlternativeNames;
      };
    }
    # Registrar
    // lib.optionalAttrs cfg.registrar.enable {
      keylime-registrar = {
        description = "Keylime Registrar";
        after = [ "network-online.target" ] ++ tlsAfter ++ (extraAfter.registrar or [ ]);
        wants = [ "network-online.target" ];
        requires = tlsAfter ++ (extraAfter.registrar or [ ]);
        inherit wantedBy;
        serviceConfig = commonServiceConfig // {
          ExecStart = "${cfg.package}/bin/keylime_registrar";
        };
      };
    }
    # Verifier
    // lib.optionalAttrs cfg.verifier.enable {
      keylime-verifier = {
        description = "Keylime Verifier";
        after = [
          "network-online.target"
        ]
        ++ lib.optional cfg.registrar.enable "keylime-registrar.service"
        ++ tlsAfter
        ++ (extraAfter.verifier or [ ]);
        wants = [ "network-online.target" ];
        requires = tlsAfter ++ (extraAfter.verifier or [ ]);
        inherit wantedBy;
        environment.PYTHONPATH = "${cfg.measuredBootPolicyPath}";
        serviceConfig = commonServiceConfig // {
          ExecStart = "${cfg.package}/bin/keylime_verifier";
        };
      };
    }
    # Auto-enrollment daemon
    // lib.optionalAttrs cfg.autoEnroll.enable {
      keylime-auto-enroll = {
        description = "Auto-enroll new Keylime agents with measured boot policy";
        after = [
          "keylime-registrar.service"
          "keylime-verifier.service"
        ]
        ++ tlsAfter;
        wants = [
          "keylime-registrar.service"
          "keylime-verifier.service"
        ];
        inherit wantedBy;
        path = [
          cfg.package
          pkgs.openssl
        ];
        environment = {
          KEYLIME_TLS_DIR = tlsDir;
          KEYLIME_POLL_INTERVAL = toString cfg.autoEnroll.pollInterval;
          KEYLIME_ENROLL_PORT = toString cfg.autoEnroll.enrollPort;
        };
        serviceConfig = commonServiceConfig // {
          ExecStart = autoEnrollScript;
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };
    }
    # Git auth daemon
    // lib.optionalAttrs git.enable {
      keylime-git-auth = {
        description = "Keylime git attestation gate (auth_request backend)";
        after = [
          "keylime-verifier.service"
        ]
        ++ tlsAfter;
        wants = [ "keylime-verifier.service" ];
        inherit wantedBy;
        environment = {
          KEYLIME_TLS_DIR = tlsDir;
          KEYLIME_AUTH_PORT = toString git.authPort;
        };
        serviceConfig = commonServiceConfig // {
          ExecStart = gitAuthScript;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    }
    # Git nginx frontend
    // lib.optionalAttrs git.enable {
      keylime-git-nginx = {
        description = "Attestation-gated git HTTP server (nginx)";
        after = [
          "keylime-git-auth.service"
          "systemd-tmpfiles-setup.service"
        ]
        ++ tlsAfter;
        wants = [ "keylime-git-auth.service" ];
        inherit wantedBy;
        serviceConfig = {
          ExecStart = "${pkgs.nginx}/bin/nginx -c /etc/keylime-git/nginx.conf -e /run/keylime-git/error.log";
          ExecReload = "${pkgs.nginx}/bin/nginx -c /etc/keylime-git/nginx.conf -e /run/keylime-git/error.log -s reload";
          Restart = "on-failure";
          RestartSec = "5s";
          User = "keylime";
          Group = "keylime";
          # Allow binding to privileged ports (e.g. 443) without running as root.
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadOnlyPaths = [
            tlsDir
            git.repoDir
          ];
          ReadWritePaths = [ "/run/keylime-git" ];
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
    }
    # Git repo init oneshots
    // lib.optionalAttrs git.enable (
      lib.listToAttrs (
        map (name: {
          name = "keylime-git-init-${name}";
          value = mkGitRepoService {
            repoDir = git.repoDir;
            inherit name wantedBy;
          };
        }) git.repos
      )
    );

  # Systemd service that generates the keylime TLS PKI on first boot.
  mkTlsService =
    {
      tlsDir,
      certDays ? 365,
      extraSans ? [ ],
      wantedBy ? [ ],
    }:
    {
      description = "Generate Keylime TLS certificates";
      inherit wantedBy;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.openssl
        pkgs.iproute2
        pkgs.coreutils
      ];
      environment = {
        KEYLIME_TLS_DIR = tlsDir;
        KEYLIME_CERT_DAYS = toString certDays;
        KEYLIME_EXTRA_SANS = builtins.toJSON extraSans;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = generateCertsScript;
      };
    };

  mkFirewallPorts =
    cfg:
    lib.optionals cfg.registrar.enable [
      (cfg.registrar.settings.tls_port or registrarDefaults.tls_port)
    ]
    ++ lib.optional cfg.verifier.enable (cfg.verifier.settings.port or verifierDefaults.port)
    ++ lib.optional cfg.autoEnroll.enable cfg.autoEnroll.enrollPort
    ++ lib.optional cfg.gitServer.enable cfg.gitServer.port;

  # Git auth daemon — same script used by system-manager and NixOS.
  gitAuthScript = pkgs.writers.writePython3 "keylime-git-auth" {
  } (builtins.readFile ./scripts/keylime-git-auth.py);

  # post-receive hook for dumb HTTP serving.
  gitPostReceiveHook = ''
    #!/bin/sh
    git update-server-info
  '';

  # nginx config for the attestation-gated git HTTP server.
  mkGitNginxConf =
    {
      cfg,
      foreground ? true,
    }:
    let
      git = cfg.gitServer;
      tlsDir = "/var/lib/keylime/tls";
    in
    ''
      ${lib.optionalString foreground "daemon off;"}
      pid /run/keylime-git/nginx.pid;
      error_log /run/keylime-git/error.log;

      events {
          worker_connections 64;
      }

      http {
          access_log /run/keylime-git/access.log;
          proxy_temp_path /run/keylime-git/tmp;
          client_body_temp_path /run/keylime-git/tmp;

          server {
              listen ${toString git.port} ssl;

              ssl_certificate     ${tlsDir}/server-cert.pem;
              ssl_certificate_key ${tlsDir}/server-key.pem;
              ssl_client_certificate ${tlsDir}/ca-cert.pem;
              ssl_verify_client on;

              set $agent_uuid "";
              if ($ssl_client_s_dn ~ "CN=([^,]+)") {
                  set $agent_uuid $1;
              }

              location = /internal/auth {
                  internal;
                  proxy_pass              http://127.0.0.1:${toString git.authPort}/verify?uuid=$agent_uuid;
                  proxy_pass_request_body off;
                  proxy_set_header        Content-Length "";
              }

              location / {
                  auth_request /internal/auth;
                  root      ${git.repoDir};
                  autoindex off;
              }
          }
      }
    '';

  # Systemd service that initialises a bare git repository on first boot.
  mkGitRepoService =
    {
      repoDir,
      name,
      wantedBy ? [ ],
    }:
    {
      description = "Initialise bare git repository ${name}";
      inherit wantedBy;
      path = [ pkgs.gitMinimal ];
      unitConfig.ConditionPathExists = "!${repoDir}/${name}.git/HEAD";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "init-git-repo-${name}" ''
          set -euo pipefail
          mkdir -p "${repoDir}"
          git init --bare "${repoDir}/${name}.git"
          # Enable dumb HTTP serving (static file index)
          git -C "${repoDir}/${name}.git" update-server-info
        '';
      };
    };

  mkTmpfilesRules =
    cfg:
    lib.optionals cfg.gitServer.enable [
      "d /var/lib/keylime-git       0750 keylime keylime -"
      "d ${cfg.gitServer.repoDir}   0750 keylime keylime -"
      "d /run/keylime-git           0750 keylime keylime -"
      "d /run/keylime-git/tmp       0750 keylime keylime -"
    ];
}
