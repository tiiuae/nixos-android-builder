# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# All custom packages, built once and passed to modules via _module.args.
{ pkgs }:
let
  tpm2-tools = pkgs.callPackage ./tpm2-tools { };
in
{
  inherit tpm2-tools;
  keylime = pkgs.callPackage ./keylime { inherit tpm2-tools; };
  keylime-agent = pkgs.callPackage ./keylime-agent { };
  keylime-git-clone = pkgs.callPackage ./keylime-git-clone { };
  measuredBoot = pkgs.callPackage ./measured-boot-state { inherit tpm2-tools; };
  attestation-ctl = pkgs.callPackage ./attestation-ctl { };
  secureBootScripts = pkgs.callPackage ./secure-boot-scripts { };
  diskInstaller = pkgs.callPackage ./disk-installer { };
}
