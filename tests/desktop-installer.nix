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

  # Secure boot is not tested here — it is already covered by the
  # desktop integration test.  The installer VM boots in UEFI setup
  # mode so unsigned UKIs work without signing or key enrollment.

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

      machine.start()
      machine.switch_root()
      machine.wait_for_unit("default.target")

      with subtest("installed system boots"):
        machine.wait_for_unit("greetd.service")

      machine.shutdown()
    '';
}
