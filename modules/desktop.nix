# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Login greeter via greetd + tuigreet.
#
# Provides a minimal shell session with U2F authentication (when keys are
# configured via yubikey-auth.nix).
{
  lib,
  pkgs,
  config,
  ...
}:
{
  config = {
    # Git is needed for nix flake operations on the bundled source tree.
    environment.systemPackages = [
      pkgs.gitMinimal
    ];

    # The desktop uses NetworkManager instead of networkd (set in base.nix).
    networking.useNetworkd = lib.mkForce false;
    networking.networkmanager.enable = true;
    networking.useDHCP = lib.mkDefault true;

    services.greetd = {
      enable = true;
      useTextGreeter = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd ${pkgs.bashInteractive}/bin/bash --greeting 'NixOS Desktop'";
        user = "greeter";
      };
    };

    # Don't auto-login with empty passwords — require U2F or explicit auth.
    security.pam.services.greetd.allowNullPassword = lib.mkForce false;
  };
}
