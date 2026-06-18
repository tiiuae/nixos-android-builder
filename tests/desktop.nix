# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  self,
  desktopModules,
  customPackages,
  lib,
  ...
}:
{
  name = "desktop-integration-test";

  # U2F authentication (YubiKey) is not tested here because pam_u2f
  # requires a real USB HID device speaking the CTAP protocol — there
  # is no practical virtual FIDO2 authenticator for NixOS VM tests.
  # Instead, we test login via password auth (groupA is empty, so
  # yubikey-auth.nix leaves PAM defaults intact).

  nodes.machine =
    { ... }:
    {
      imports = desktopModules;
      config = {
        _module.args = { inherit customPackages self; };

        # Clear YubiKey groups so yubikey-auth.nix leaves PAM defaults
        # intact and falls back to password auth. pam_u2f cannot be
        # tested in QEMU — it requires a real USB HID FIDO2 device.
        nixosAndroidBuilder.yubikeys.groupA = lib.mkForce [ ];
        nixosAndroidBuilder.yubikeys.groupB = lib.mkForce [ ];

        # Set a known password for the test user so we can log in
        # through tuigreet without U2F.
        users.users.user.hashedPassword = "$6$0kZnFhhiulKUACXN$B83f7jPk8ZF2R1.wAMbM/IXuqvV6Ub41K2vrH6evE5EeCK51v9l/gTGATe8dkt2a19DRt9caZwrr7CIsOV1s0."; # "test"

        virtualisation = lib.mkVMOverride {
          diskSize = 30 * 1024;
          memorySize = 8 * 1024;
          cores = 8;
          writableStore = false;
          mountHostNixStore = false;
        };
      };
    };

  testScript =
    { nodes, ... }:
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

      with subtest("greetd is running"):
        machine.wait_for_unit("greetd.service")

      with subtest("secure boot works"):
        _status, stdout = machine.execute("bootctl status")
        assert "Secure Boot: enabled (user)" in stdout, \
          f"Secure Boot is NOT active: {stdout}"

      with subtest("root is ext4 on disk"):
        output = machine.succeed("mount | grep ' / '")
        assert "ext4" in output, f"root is not ext4: {output}"
        assert "rw" in output, f"root is not writable: {output}"

      with subtest("root partition was grown by systemd-repart"):
        # The minimized image root is ~2-3 GB; after repart it should fill
        # the 30 GB virtual disk.  Check that root is at least 20 GB.
        output = machine.succeed("df --output=size -BG / | tail -1").strip()
        size_gb = int(output.rstrip("G"))
        assert size_gb >= 20, \
          f"Root partition too small ({size_gb}G), systemd-repart may not have grown it"

      with subtest("network is configured"):
        # NetworkManager should be running and an interface should have an IP.
        machine.wait_for_unit("NetworkManager.service")
        machine.wait_until_succeeds("ip -4 addr show | grep -q 'inet '", timeout=30)

      with subtest("nix with flakes is available"):
        machine.succeed("nix --version")
        output = machine.succeed("nix show-config 2>&1 | grep experimental-features")
        assert "flakes" in output, f"flakes not enabled: {output}"

      with subtest("git is available"):
        machine.succeed("git --version")

      with subtest("data persists across reboot"):
        machine.succeed("echo 'hello-desktop' > /home/user/sentinel")
        machine.succeed("cat /home/user/sentinel")

        machine.reboot()
        machine.wait_for_unit("default.target")

        output = machine.succeed("cat /home/user/sentinel").strip()
        assert output == "hello-desktop", \
          f"Expected 'hello-desktop', got '{output}'"

      with subtest("flake source is available"):
        machine.succeed("test -d /home/user/nixos-android-builder")
        machine.succeed("test -f /home/user/nixos-android-builder/flake.nix")
        machine.succeed("test -f /home/user/nixos-android-builder/flake.lock")

      with subtest("login yields a shell session"):
        # tuigreet shows the greeting on tty1; type credentials and
        # verify we land in a shell.
        machine.wait_until_tty_matches("1", "NixOS Desktop")
        machine.send_chars("user\n")
        machine.sleep(1)
        machine.send_chars("test\n")
        # After login, tuigreet hands off to bash (the default --cmd).
        machine.wait_until_tty_matches("1", "user@")

      machine.shutdown()
    '';
}
