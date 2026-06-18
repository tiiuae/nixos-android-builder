# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# End-to-end VM test for the attestation-gated git server.
#
# This uses a real keylime registrar, verifier, and agent with an
# emulated TPM.  The full attestation pipeline is exercised before
# git access is tested.
#
# Test cases:
#   - No client cert              → 400 (nginx ssl_verify_client)
#   - Cert from untrusted CA      → 400/TLS error
#   - Valid cert, UUID unknown    → 403 (not enrolled in verifier)
#   - Valid cert, UUID attested   → 200, git clone succeeds
#   - UUID revoked (tenant delete)→ 403
#   - Re-enrolled                 → clone succeeds again
#
# Two VMs:
#   server  - keylime registrar + verifier + auto-enroll + git server
#   agent   - keylime agent with TPM (also acts as the git client)
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
  caKey = "${tlsDir}/ca-key.pem";
  clientCert = "${tlsDir}/client-cert.pem";
  clientKey = "${tlsDir}/client-key.pem";

  repoDir = "/var/lib/keylime-git/repos";
  gitPort = 443;

  unknownUuid = "ffffffff-ffff-ffff-ffff-ffffffffffff";

in
{
  name = "keylime-git-server";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ keylimeModule ];
      _module.args = { inherit customPackages; };

      virtualisation.tpm.enable = true;

      environment.systemPackages = [
        pkgs.curl
        pkgs.git
        pkgs.openssl
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
        autoEnroll = {
          enable = true;
          pollInterval = 2;
        };
        gitServer = {
          enable = true;
          repos = [ "test" ];
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
        pkgs.gitMinimal
        pkgs.openssl
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
        description = "Keylime agent configuration provisioned";
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
    ''
      import subprocess, os, json

      subprocess.run([
          "${lib.getExe nodes.agent.system.build.prepareWritableDisk}"
      ], env=os.environ.copy(), cwd=agent.state_dir, check=True)

      tenant = "-r 127.0.0.1 -rp 8891 -v 127.0.0.1 -vp 8881"
      agent_cert = "/run/keylime-git/client-cert.pem"
      agent_key = "/run/keylime-git/client-key.pem"

      def gen_cert(cn, ca_cert, ca_key, prefix):
          """Generate a key + CA-signed cert on the server."""
          server.succeed(
              f"openssl req -newkey rsa:2048 -nodes"
              f" -keyout /tmp/{prefix}-key.pem"
              f" -out /tmp/{prefix}.csr"
              f" -subj '/CN={cn}'"
              f" && openssl x509 -req"
              f" -in /tmp/{prefix}.csr"
              f" -CA {ca_cert} -CAkey {ca_key}"
              f" -CAcreateserial"
              f" -out /tmp/{prefix}-cert.pem"
              f" -days 1 -sha256"
          )

      def copy_to_agent(*names):
          """Copy files from server /tmp to agent /tmp."""
          for name in names:
              content = server.succeed(f"cat /tmp/{name}")
              agent.succeed(
                  f"cat > /tmp/{name}"
                  f" << 'CERT_EOF'\n{content}\nCERT_EOF"
              )

      def http_status(cert, key, path="/test.git"):
          """Return the HTTP status code for info/refs."""
          return agent.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}'"
              f" --cert {cert} --key {key}"
              f" --cacert /tmp/ca-cert.pem"
              f" '{git_base}{path}/info/refs"
              f"?service=git-upload-pack'"
              f" || true"
          ).strip()

      def git_clone(cert, key, dest):
          return (
              f"git"
              f" -c http.sslCert={cert}"
              f" -c http.sslKey={key}"
              f" -c http.sslCAInfo=/tmp/ca-cert.pem"
              f" clone {git_base}/test.git {dest}"
          )

      serial_stdout_off()
      server.start()
      agent.start(allow_reboot=True)
      server.wait_for_unit("multi-user.target")
      agent.wait_for_unit("multi-user.target")

      with subtest("Configure agent and wait for attestation"):
          server_ip = server.succeed(
              "ip -4 -o addr show eth1"
              " | awk '{print $4}' | cut -d/ -f1"
          ).strip()
          server.log(f"Server IP: {server_ip}")
          git_base = (
              f"https://{server_ip}:${toString gitPort}"
          )

          server.wait_for_open_port(8891)
          server.wait_for_open_port(8881)

          ca_cert_pem = server.succeed("cat ${caCert}")
          server_json = json.dumps(
              {"ip": server_ip, "ca_cert": ca_cert_pem}
          )
          agent.succeed("mount -o remount,rw /boot")
          agent.succeed(
              f"cat > /boot/attestation-server.json"
              f" << 'EOF'\n{server_json}\nEOF"
          )
          agent.succeed("mount -o remount,ro /boot")
          agent.succeed(
              "systemctl start"
              " keylime-agent-config.service"
          )
          agent.wait_for_unit("keylime-agent.service")

          agent.wait_until_succeeds(
              f"test -f {agent_cert}", timeout=300
          )

          resp = json.loads(server.succeed(
              "curl -sk"
              " --cert ${clientCert}"
              " --key ${clientKey}"
              " --cacert ${caCert}"
              " https://127.0.0.1:8891/v2.5/agents/"
          ))
          agent_uuid = resp["results"]["uuids"][0]
          server.log(f"Agent UUID: {agent_uuid}")

      with subtest("Generate test certs for error cases"):
          gen_cert(
              "${unknownUuid}",
              "${caCert}", "${caKey}", "unknown",
          )
          server.succeed(
              "openssl req -x509 -newkey rsa:2048 -nodes"
              " -keyout /tmp/rogue-ca-key.pem"
              " -out /tmp/rogue-ca-cert.pem"
              " -days 1 -subj '/CN=Rogue CA'"
              " -addext"
              " 'basicConstraints=critical,CA:TRUE'"
          )
          gen_cert(
              "rogue",
              "/tmp/rogue-ca-cert.pem",
              "/tmp/rogue-ca-key.pem",
              "rogue",
          )
          copy_to_agent(
              "unknown-cert.pem", "unknown-key.pem",
              "rogue-cert.pem", "rogue-key.pem",
          )
          ca_pem = server.succeed("cat ${caCert}")
          agent.succeed(
              f"cat > /tmp/ca-cert.pem"
              f" << 'CERT_EOF'\n{ca_pem}\nCERT_EOF"
          )

      with subtest("Seed test git repository"):
          server.wait_for_unit(
              "keylime-git-init-test.service"
          )
          server.succeed(
              "git -C /tmp init seed"
              " && git -C /tmp/seed"
              "    config user.email t@t.t"
              " && git -C /tmp/seed"
              "    config user.name Test"
              " && echo 'hello from keylime'"
              "    > /tmp/seed/README"
              " && git -C /tmp/seed add ."
              " && git -C /tmp/seed commit -m init"
              " && git -C /tmp/seed push"
              "    ${repoDir}/test.git HEAD:main"
              " && git -C ${repoDir}/test.git"
              "    symbolic-ref HEAD refs/heads/main"
              " && git -C ${repoDir}/test.git"
              "    update-server-info"
          )

      with subtest("Wait for git server"):
          server.wait_for_open_port(${toString gitPort})

      with subtest("Reject: no client certificate"):
          status = agent.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}'"
              f" --cacert /tmp/ca-cert.pem"
              f" '{git_base}/test.git/info/refs"
              f"?service=git-upload-pack'"
              f" || true"
          ).strip()
          assert status in ("400", "000"), (
              f"Expected 400/000, got {status}"
          )

      with subtest("Reject: cert signed by untrusted CA"):
          status = agent.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}'"
              f" --cert /tmp/rogue-cert.pem"
              f" --key /tmp/rogue-key.pem"
              f" --cacert /tmp/ca-cert.pem"
              f" '{git_base}/test.git/info/refs"
              f"?service=git-upload-pack'"
              f" || true"
          ).strip()
          assert status in ("400", "000"), (
              f"Expected 400/000, got {status}"
          )

      with subtest("Deny: valid cert, UUID not enrolled"):
          status = http_status(
              "/tmp/unknown-cert.pem",
              "/tmp/unknown-key.pem",
          )
          assert status == "403", (
              f"Expected 403, got {status}"
          )

      with subtest("Allow: attested agent info/refs"):
          status = http_status(agent_cert, agent_key)
          assert status == "200", (
              f"Expected 200, got {status}"
          )

      with subtest("Allow: attested agent git clone"):
          agent.succeed(
              git_clone(
                  agent_cert, agent_key, "/tmp/cloned"
              )
          )
          readme = agent.succeed(
              "cat /tmp/cloned/README"
          ).strip()
          assert readme == "hello from keylime", (
              f"Unexpected: {readme!r}"
          )

      with subtest("Revoke: clone forbidden after delete"):
          server.succeed(
              f"keylime_tenant -c delete"
              f" -u {agent_uuid} {tenant}"
          )
          status = http_status(agent_cert, agent_key)
          assert status == "403", (
              f"Expected 403, got {status}"
          )
          agent.fail(git_clone(
              agent_cert, agent_key,
              "/tmp/cloned-after-revoke",
          ))

      with subtest("Re-enroll: clone succeeds again"):
          mb_refstate = agent.succeed(
              "measure-boot-state"
          )
          server.succeed(
              f"cat > /tmp/mb-refstate.json"
              f" << 'EOF'\n{mb_refstate}\nEOF"
          )
          server.succeed(
              f"keylime_tenant --push-model"
              f" -c add -t 192.168.1.1"
              f" -u {agent_uuid} {tenant}"
              f" --mb_refstate"
              f" /tmp/mb-refstate.json"
          )
          server.wait_until_succeeds(
              f"keylime_tenant -c cvstatus"
              f" -u {agent_uuid} {tenant}"
              " 2>&1 | grep -qE"
              " '\"operational_state\":"
              " \"(Get Quote|Provide V)\"'",
              timeout=60,
          )
          agent.succeed(git_clone(
              agent_cert, agent_key,
              "/tmp/recloned",
          ))
          agent.succeed(
              "test -f /tmp/recloned/README"
          )
    '';
}
