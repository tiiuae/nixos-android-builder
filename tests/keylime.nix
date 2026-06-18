# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Core keylime test: registration, attestation, tampered refstate
# rejection, and push-mode timeout recovery.
#
# Two VMs:
#   server  - registrar + verifier (tls.autoGenerate)
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
  name = "keylime";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ keylimeModule ];
      _module.args = { inherit customPackages; };
      virtualisation.tpm.enable = true;
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        tpm2-tools
      ];
      services.keylime = {
        enable = true;
        logLevel = "DEBUG";
        registrar.enable = true;
        verifier = {
          enable = true;
          settings.mode = "push";
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
        tpm2-tools
        measuredBoot.measure-boot-state
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
    };

  testScript =
    { nodes, ... }:
    let
      curl = lib.concatStringsSep " " [
        "curl -sk"
        "--cert ${clientCert}"
        "--key ${clientKey}"
        "--cacert ${caCert}"
      ];
      tenant = lib.concatStringsSep " " [
        "keylime_tenant"
        "-r 127.0.0.1 -rp 8891"
        "-v 127.0.0.1 -vp 8881"
      ];
    in
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

      with subtest("Agent registers"):
          agent_uuid = server.wait_until_succeeds(
              "${curl}"
              " https://127.0.0.1:8891/v2.5/agents/"
              " | jq -re '.results.uuids[0]'",
              timeout=30,
          ).strip()
          server.log(f"Agent UUID: {agent_uuid}")

      with subtest("Enroll with measured boot policy"):
          mb_refstate = agent.succeed(
              "measure-boot-state"
          )
          server.succeed(
              "cat > /tmp/mb-refstate.json"
              f" << 'EOF'\n{mb_refstate}\nEOF"
          )
          server.succeed(
              f"${tenant} --push-model"
              f" -c add -t 192.168.1.1"
              f" -u {agent_uuid}"
              " --mb_refstate /tmp/mb-refstate.json"
          )

      with subtest("Agent attested"):
          server.wait_until_succeeds(
              "${curl}"
              f" https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              " | jq -re '.results.attestation_status'"
              " | grep -q PASS",
              timeout=60,
          )

      with subtest("Tampered refstate is rejected"):
          tampered = json.loads(mb_refstate)
          tampered["uki_digest"] = {
              "sha256": "0x" + "00" * 32
          }
          server.succeed(
              "cat > /tmp/tampered.json"
              f" << 'EOF'\n{json.dumps(tampered)}\nEOF"
          )
          server.succeed(
              f"${tenant} -c delete -u {agent_uuid}"
          )
          server.succeed(
              f"${tenant} --push-model"
              f" -c add -t 192.168.1.1"
              f" -u {agent_uuid}"
              " --mb_refstate /tmp/tampered.json"
          )
          server.wait_until_succeeds(
              "journalctl -u keylime-verifier"
              " --no-pager"
              " | grep -q 'policy violations'",
              timeout=90,
          )

      with subtest("Push-mode timeout recovery"):
          server.succeed(
              f"${tenant} -c delete -u {agent_uuid}"
          )
          server.succeed(
              f"${tenant} --push-model"
              f" -c add -t 192.168.1.1"
              f" -u {agent_uuid}"
              " --mb_refstate /tmp/mb-refstate.json"
          )
          server.wait_until_succeeds(
              "${curl}"
              f" https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              " | jq -re '.results.attestation_status'"
              " | grep -q PASS",
              timeout=60,
          )
          baseline = int(server.succeed(
              "${curl}"
              f" https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              " | jq -r '.results.attestation_count'"
          ).strip() or "0")

          agent.succeed(
              "systemctl stop keylime-agent.service"
          )
          server.wait_until_succeeds(
              "${curl}"
              f" https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              " | jq -re '.results.attestation_status'"
              " | grep -q FAIL",
              timeout=30,
          )

          agent.succeed(
              "systemctl start keylime-agent.service"
          )
          agent.wait_for_unit("keylime-agent.service")
          server.wait_until_succeeds(
              "${curl}"
              f" https://127.0.0.1:8881/v2.5/agents/"
              f"{agent_uuid}"
              f" | jq -re"
              f" 'select(.results.attestation_count"
              f" > {baseline})"
              f" | .results.attestation_status'"
              " | grep -q PASS",
              timeout=120,
          )
    '';
}
