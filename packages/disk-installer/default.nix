# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  writers,
  writeShellApplication,
  jq,
  mtools,
  util-linux,
  sbsigntool,
  gptfdisk,
}:
{

  module = import ./installer.nix;
  vm = import ./installer-vm.nix;

  # Python script to be run on the local machine in order to
  # pre-configure the installer for unattended installation
  # and sign UKIs
  configure = writers.writePython3Bin "configure-disk-image" {
    makeWrapperArgs = [
      "--prefix PATH : ${
        lib.makeBinPath [
          util-linux
          mtools
          sbsigntool
        ]
      }"
    ];
  } ./configure-disk-image.py;

  # Shell script that runs during early-boot from initrd and
  # copies itself to the target disk.
  run = writeShellApplication {
    name = "run-disk-installer";
    runtimeInputs = [
      jq
      gptfdisk
      # some dependencies are in boot.initrd.systemd.extraBin,
      # as we don't want to pull their whole store paths into the
      # initrd for just a few binaries: lsblk, ddrescue, dialog,
      # systemd-cat.
    ];
    excludeShellChecks = [ "SC2086" ];
    text = builtins.readFile ./run.sh;
  };

}
