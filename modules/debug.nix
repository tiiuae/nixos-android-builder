# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Support debug builds with interactive login & extra software.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.nixosAndroidBuilder.debug = lib.mkEnableOption "image customizations for interactive access during run-time";

  config = lib.mkIf config.nixosAndroidBuilder.debug {
    # Add extra software from nixpkgs for convenience.
    environment.systemPackages = with pkgs; [
      vim
      htop
      tmux
      gitMinimal
    ];

    # Allow password-less sudo for wheel users
    security.sudo.wheelNeedsPassword = false;

    # Enable unauthenticated shell if early boot fails
    boot.initrd.systemd.emergencyAccess = true;

    boot.kernelParams = [
      "rd.systemd.debug_shell=tty3"
      "systemd.debug_shell=tty3"
    ];

    # Add grep to the initrd. Feel free to remove, this just makes
    # inspection and debugging in an emergency shell much more convenient.
    boot.initrd.systemd.initrdBin = [ pkgs.gnugrep ];
  };
}
