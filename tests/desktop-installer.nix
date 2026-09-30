# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  desktopInstallerModules,
  payload,
  lib,
  vmInstallerTarget,
  ...
}:
{
  name = "desktop-installer-test";
  nodes.machine = {
    imports = desktopInstallerModules;
    config = {
      testing.initrdBackdoor = true;
      diskInstaller = {
        payload = lib.mkForce payload;
        inherit vmInstallerTarget;
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
        "2", "Please remove the installation media"
      )
      machine.send_key("\n")

      machine.shutdown()

      # Swap the target disk into the boot position.
      subprocess.run([
        "mv", "empty0.qcow2", "${nodes.machine.virtualisation.diskImage}"
      ], cwd=machine.state_dir)

      # First boot enrolls the Secure Boot keys and reboots; wait for
      # the second firmware boot before interacting with the initrd.
      machine.start(allow_reboot=True)
      machine.wait_for_console_text(
        r"BdsDxe: starting[\s\S]*BdsDxe: starting", timeout=300
      )
      machine.switch_root()
      machine.wait_for_unit("default.target")

      with subtest("installed system boots"):
        machine.wait_for_unit("greetd.service")

      with subtest("installed system runs with Secure Boot enabled"):
        _status, stdout = machine.execute("bootctl status")
        assert "Secure Boot: enabled (user)" in stdout, \
          f"Secure Boot is NOT active: {stdout}"

      machine.shutdown()
    '';
}
