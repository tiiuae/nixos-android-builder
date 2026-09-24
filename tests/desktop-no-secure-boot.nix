# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Boot the desktop on firmware without Secure Boot and check that the
# initrd halts with an error instead of booting into the system.
{
  self,
  desktopModules,
  customPackages,
  lib,
  hostPkgs,
  ...
}:
{
  name = "desktop-no-secure-boot";

  nodes.machine =
    { config, ... }:
    {
      imports = desktopModules;
      config = {
        _module.args = { inherit customPackages self; };

        virtualisation = lib.mkVMOverride {
          useSecureBoot = false;
          efi.OVMF = config.virtualisation.host.pkgs.OVMF.fd;
          diskSize = 30 * 1024;
          memorySize = 4 * 1024;
          writableStore = false;
          mountHostNixStore = false;
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      cfg = nodes.machine.virtualisation;
      image = "${nodes.machine.system.build.image}/${nodes.machine.image.fileName}";
    in
    ''
      import subprocess
      import time

      # Unsigned copy of the image: no Secure Boot keys on the ESP.
      subprocess.run([
        "${cfg.qemu.package}/bin/qemu-img", "convert",
        "-f", "raw", "-O", "raw", "${image}", "${cfg.diskImage}",
      ], cwd=machine.state_dir, check=True)
      subprocess.run([
        "${cfg.qemu.package}/bin/qemu-img", "resize",
        "${cfg.diskImage}", "${toString cfg.diskSize}M",
      ], cwd=machine.state_dir, check=True)

      serial_stdout_on()
      machine.start()

      with subtest("initrd refuses to boot without Secure Boot"):
        machine.wait_for_console_text("Secure Boot is neither active nor in setup mode", timeout=300)

      with subtest("error dialog shuts the machine down"):
        # Only the fatal-error dialog powers off on Enter, so a shutdown
        # here also shows the boot did not continue past the initrd.
        # Give the dialog time to draw, then press its Shutdown button.
        time.sleep(10)
        machine.screenshot("before-enter")
        machine.send_key("ret")
        assert machine.process is not None
        machine.process.wait(timeout=60)
        machine.wait_for_shutdown()
    '';
}
