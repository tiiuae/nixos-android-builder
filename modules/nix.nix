# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Enable nix with flake support, no channels.
{
  lib,
  ...
}:
{
  config = {
    nix = {
      enable = lib.mkForce true;
      channel.enable = false;
      settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };
}
