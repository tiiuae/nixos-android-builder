# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  installerModules,
  payload,
  lib,
  vmInstallerTarget,
  vmStorageTarget,
  ...
}:
{
  name = "nixos-android-builder-installer-test-${vmInstallerTarget}";
  nodes.machine = {
    imports = installerModules;
    config = {
      testing.initrdBackdoor = true;
      diskInstaller = {
        payload = lib.mkForce payload;
        inherit vmInstallerTarget vmStorageTarget;
      };
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import subprocess

      subprocess.run([
        "${lib.getExe nodes.machine.system.build.prepareInstallerDisk}"
      ], cwd=machine.state_dir, check=True)

      serial_stdout_on()
      machine.start()

      machine.wait_until_tty_matches(
        "2", "Select a disk to install to"
      )
      machine.screenshot("installer.png")
      # Press enter to confirm default disk
      machine.send_key("\n")

      machine.wait_until_tty_matches(
        "2", "About to install from"
      )
      machine.screenshot("installer-confirm.png")
      machine.wait_until_tty_matches(
        "2", "Copying source disk"
      )
      machine.screenshot("installer-copying.png")

      machine.wait_until_tty_matches(
        "2", "Please remove the installation media"
      )
      machine.screenshot("installer-done.png")
      machine.send_key("\n")

      machine.shutdown()

      subprocess.run([
        "mv", "empty0.qcow2", "${nodes.machine.virtualisation.diskImage}"
      ], cwd=machine.state_dir)
      subprocess.run([
        "ls"
      ], cwd=machine.state_dir)

      machine.start()

      machine.wait_until_tty_matches(
        "2", "Select a disk to store build artifacts in"
      )
      machine.screenshot("installer-artifacts.png")
      machine.send_key("down")
      machine.send_key("\n")

      machine.switch_root()
      machine.wait_for_unit("multi-user.target")
      machine.shutdown()
    '';
}
