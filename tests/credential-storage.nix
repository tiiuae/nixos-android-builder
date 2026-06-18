# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib, ... }:
{
  name = "credential-storage";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        ../modules/credential-storage.nix
      ];

      config = {
        virtualisation.tpm.enable = true;

        nixosAndroidBuilder.credentialStorage.enable = true;

        # Use a tmpfs to simulate the dedicated credentials partition
        fileSystems."/var/lib/credentials" = lib.mkForce {
          device = "none";
          fsType = "tmpfs";
          options = [
            "size=64m"
            "mode=0700"
          ];
        };
      };
    };

  testScript = ''
    serial_stdout_off()
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("credential-store is available"):
        machine.succeed("credential-store list || true")

    with subtest("add and show a credential"):
        machine.succeed("echo 's3cret-value' | credential-store add test-token")
        output = machine.succeed("credential-store show test-token").strip()
        assert output == "s3cret-value", f"Expected 's3cret-value', got '{output}'"

    with subtest("add credential from file"):
        machine.succeed("echo 'file-secret' > /tmp/secret.txt")
        machine.succeed("credential-store add file-token /tmp/secret.txt")
        output = machine.succeed("credential-store show file-token").strip()
        assert output == "file-secret", f"Expected 'file-secret', got '{output}'"

    with subtest("list shows stored credentials"):
        output = machine.succeed("credential-store list")
        assert "test-token" in output
        assert "file-token" in output

    with subtest("remove a credential"):
        machine.succeed("credential-store remove test-token")
        output = machine.succeed("credential-store list")
        assert "test-token" not in output

    with subtest("invalid names are rejected"):
        machine.fail("echo 'bad' | credential-store add '../escape'")
        machine.fail("echo 'bad' | credential-store add '.hidden'")
        machine.fail("echo 'bad' | credential-store add '-dash'")

    with subtest("encrypted file is not plaintext"):
        content = machine.succeed("cat /var/lib/credentials/file-token")
        assert "file-secret" not in content, "Credential stored in plaintext!"
  '';
}
