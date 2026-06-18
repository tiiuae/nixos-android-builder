# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  imageModules,
  customPackages,
  lib,
  ...
}:
{
  name = "nixos-android-builder-integration-test";
  nodes.machine =
    { ... }:
    {
      imports = imageModules;
      config = {
        _module.args = { inherit customPackages; };
        nixosAndroidBuilder.unattended.enable = lib.mkForce false;
        # Decrease resource usage for VM tests a bit as long as we are not actually
        # building android as part of the test suite.
        systemd.repart.partitions."40-var-lib-build".SizeMinBytes = lib.mkVMOverride "10G";
        virtualisation = lib.mkVMOverride {
          diskSize = 30 * 1024;
          memorySize = 8 * 1024;
          cores = 8;
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      testFHSEnv = ''
        with subtest("Checking FHS Environment"):
          with subtest("/usr/bin/env can be executed"):
            t.assertIn(
              "env (GNU coreutils)", machine.succeed("/usr/bin/env --version"),
              "/usr/bin/env --version can't be executed"
            )
          with subtest("Executables in /bin can be run"):
             t.assertIn(
              "diff (GNU diffutils)", machine.succeed("/bin/diff -v"),
              "failed to execute /bin/diff -v"
            )
          with subtest("/bin/bash sets default $PATH and is a regular file with the correct linker"):
            t.assertIn(
              "/bin", machine.succeed("env -i /bin/bash -c 'echo $PATH'"),
              "/bin/bash does not have /bin in $PATH if run in an empty environment"
            )

            file_bin_bash = machine.succeed("file /bin/bash")
            t.assertIn(
              "interpreter /lib/ld-linux-x86-64.so.2", file_bin_bash,
              "/bin/bash does not have the right dynamic linker set"
            )
            t.assertNotIn(
              "symbolic link to ", file_bin_bash,
              "/bin/bash should not be a symlink"
            )

          with subtest("dynamic linkers exist as regular files in /lib(64) and search /lib"):
            t.assertNotIn(
              "symbolic link to ", machine.succeed("file /lib/ld-linux-x86-64.so.2"),
              "/lib/ld-linux-x86-64.so.2 should not be a symlink"
            )
            t.assertNotIn(
              "symbolic link to ", machine.succeed("file /lib64/ld-linux-x86-64.so.2"),
              "/lib64/ld-linux-x86-64.so.2 should not be a symlink"
            )

            t.assertIn(
              " /lib (system search path)", machine.succeed("/lib/ld-linux-x86-64.so.2 --help"),
              "search path of /lib/ld-linux-x86-64.so.2 does not contain /lib ")
      '';

      testVerity = ''
        with subtest("dm-verity works"):
          t.assertRegex(
          machine.succeed("veritysetup status usr"),
          r'status:\s+verified')
      '';

      testSecureBoot = ''
        with subtest("secure boot works"):
          _status, stdout = machine.execute("bootctl status")
          t.assertIn(
            "Secure Boot: enabled (user)", stdout,
            "Secure Boot is NOT active")
      '';

      testPersistence = ''
        with subtest("Partition persistence"):
          with subtest("Write sentinel files before reboot"):
            machine.succeed("echo 'build-data' > /var/lib/build/sentinel")
            machine.succeed("echo 'keylime-data' > /var/lib/keylime/sentinel")
            machine.succeed("echo 'cred-data' > /var/lib/credentials/sentinel")

            # Verify all three are readable
            machine.succeed("cat /var/lib/build/sentinel")
            machine.succeed("cat /var/lib/keylime/sentinel")
            machine.succeed("cat /var/lib/credentials/sentinel")

          machine.reboot()
          machine.wait_for_unit("default.target")

          with subtest("/var/lib/build is ephemeral (wiped on reboot)"):
            machine.fail("test -f /var/lib/build/sentinel")

          with subtest("/var/lib/keylime persists across reboot"):
            output = machine.succeed("cat /var/lib/keylime/sentinel").strip()
            assert output == "keylime-data", f"Expected 'keylime-data', got '{output}'"

          with subtest("/var/lib/credentials persists across reboot"):
            output = machine.succeed("cat /var/lib/credentials/sentinel").strip()
            assert output == "cred-data", f"Expected 'cred-data', got '{output}'"
      '';
    in
    ''
      import os
      import os.path
      import subprocess
      env = os.environ.copy()

      # Prepare the writable disk image
      subprocess.run([
        "${lib.getExe nodes.machine.system.build.prepareWritableDisk}"
      ], env=env, cwd=machine.state_dir, check=True)

      serial_stdout_on()
      machine.start(allow_reboot=True)
      machine.wait_for_unit("default.target")
      ${testSecureBoot}
      ${testVerity}
      ${testFHSEnv}
      ${testPersistence}
      machine.shutdown()
    '';
}
