# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Interactive desktop configuration for building and configuring the
# other nixosConfigurations in this repository.
{
  config = {
    system.name = "desktop";

    # Enable debug shell on tty3 and verbose boot logging.
    nixosAndroidBuilder.debug = true;

    # Basic interactive tools and passwordless sudo come from debug.nix.
    # Login greeter and session picker come from modules/desktop.nix.
    # U2F authentication comes from modules/yubikey-auth.nix.

    # YubiKey groups — override in a machine-specific config.
    # Generate keys with:
    #   pamu2fcfg -N -i "pam://nixos-android-builder" -o "pam://nixos-android-builder" -u "user"
    nixosAndroidBuilder.yubikeys.groupA = [ ];
    nixosAndroidBuilder.yubikeys.groupB = [ ];
  };
}
