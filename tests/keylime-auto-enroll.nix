# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Test: auto-enrollment of keylime agents with measured boot policy.
#
# Verifies that the auto-enrollment daemon automatically enrolls a
# new agent when it both registers with the registrar AND reports
# its measured boot reference state.
#
# Two VMs:
#   server  - registrar + verifier + auto-enroll
#   agent   - keylime agent with TPM
{
  keylimeModule,
  keylimeAgentModule,
  keylimeAgentPackage,
  customPackages,
  imageModules,
  lib,
  pkgs,
  ...
}:
let
  inherit (customPackages) tpm2-tools measuredBoot;
  tlsDir = "/var/lib/keylime/tls";
  caCert = "${tlsDir}/ca-cert.pem";
  clientCert = "${tlsDir}/client-cert.pem";
  clientKey = "${tlsDir}/client-key.pem";
in
{
  name = "keylime-auto-enroll";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ keylimeModule ];
      _module.args = { inherit customPackages; };
      virtualisation.tpm.enable = true;
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
      services.keylime = {
        enable = true;
        registrar.enable = true;
        verifier = {
          enable = true;
          settings.mode = "push";
        };
        autoEnroll = {
          enable = true;
          pollInterval = 2;
        };
      };
    };

  nodes.agent =
    { config, lib, ... }:
    {
      imports = imageModules ++ [ keylimeAgentModule ];
      _module.args = { inherit customPackages; };
      system.name = lib.mkForce "agent";
      virtualisation = lib.mkVMOverride {
        diskSize = 8 * 1024;
        memorySize = 2 * 1024;
        cores = 2;
      };
      systemd.repart.partitions."40-var-lib-build".SizeMinBytes = lib.mkVMOverride "1G";
      nixosAndroidBuilder.unattended.enable = lib.mkForce false;
      environment.systemPackages = [
        pkgs.coreutils
        pkgs.curl
        pkgs.openssl
        measuredBoot.report-measured-boot-state
      ];
      systemd.tmpfiles.rules = [
        "d ${tlsDir} 0750 keylime keylime -"
      ];
      services.keylime-agent = {
        enable = true;
        settings = {
          contact_ip = lib.mkForce "192.168.1.1";
          attestation_interval_seconds = lib.mkForce 2;
        };
      };
      systemd.services.keylime-agent-config = {
        description = "Keylime agent config provisioned";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
      systemd.services.keylime-agent = {
        after = [ "keylime-agent-config.service" ];
        requires = [ "keylime-agent-config.service" ];
      };
      systemd.services.keylime-report-measured-boot-state.wantedBy = lib.mkForce [ ];
    };

  testScript =
    { nodes, ... }:
    ''
      import subprocess, os, json

      subprocess.run([
          "${lib.getExe nodes.agent.system.build.prepareWritableDisk}"
      ], env=os.environ.copy(), cwd=agent.state_dir, check=True)

      serial_stdout_off()
      server.start()
      agent.start(allow_reboot=True)
      server.wait_for_unit("multi-user.target")
      agent.wait_for_unit("multi-user.target")

      with subtest("Configure and start agent"):
          server_ip = server.succeed(
              "ip -4 -o addr show eth1"
              " | awk '{print $4}' | cut -d/ -f1"
          ).strip()

          server.wait_for_open_port(8891)
          server.wait_for_open_port(8881)

          ca_cert_pem = server.succeed(
              "cat ${caCert}"
          )
          server_json = json.dumps(
              {"ip": server_ip, "ca_cert": ca_cert_pem}
          )
          agent.succeed("mount -o remount,rw /boot")
          agent.succeed(
              "cat > /boot/attestation-server.json"
              f" << 'EOF'\n{server_json}\nEOF"
          )
          agent.succeed("mount -o remount,ro /boot")
          agent.succeed(
              "systemctl start"
              " keylime-agent-config.service"
          )
          agent.wait_for_unit("keylime-agent.service")

      with subtest("Agent registers with registrar"):
          agent_uuid = server.wait_until_succeeds(
              "curl -sk"
              " --cert ${clientCert}"
              " --key ${clientKey}"
              " --cacert ${caCert}"
              " https://127.0.0.1:8891/v2.5/agents/"
              " | jq -re '.results.uuids[0]'",
              timeout=30,
          ).strip()
          server.log(f"Agent UUID: {agent_uuid}")

      with subtest("Report measured boot state"):
          agent.succeed("report-measured-boot-state")

      with subtest("Auto-enrolled and attested"):
          server.wait_until_succeeds(
              "curl -sk"
              " --cert ${clientCert}"
              " --key ${clientKey}"
              " --cacert ${caCert}"
              " https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              " | grep -q operational_state",
              timeout=60,
          )

      with subtest("Git client cert provisioned"):
          agent.wait_until_succeeds(
              "test -f"
              " /run/keylime-git/client-cert.pem",
              timeout=300,
          )
          agent.succeed(
              "test -f"
              " /run/keylime-git/client-key.pem"
          )
          cn = agent.succeed(
              "openssl x509 -noout -subject"
              " -in /run/keylime-git/"
              "client-cert.pem"
          ).strip()
          assert agent_uuid in cn, (
              f"Cert CN should contain {agent_uuid},"
              f" got: {cn}"
          )
    '';
}
