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

    # Enroll one PIV card per group (touch only, no PIN), then paste the
    # printed entries here:
    #   piv-multiparty-enroll -u user -g A --no-pin-code
    #   piv-multiparty-enroll -u user -g B --no-pin-code
    # security.pam.multiparty.entries.user = [
    #   { group = "A"; spki = "MFkw..."; requirePin = false; }
    #   { group = "B"; spki = "MFkw..."; requirePin = false; }
    # ];
    #
    # The SPKI can be re-derived at any time from the certificate stored on
    # the card, no reset needed:
    #   yubico-piv-tool -a read-certificate -s 9a \
    #     | openssl x509 -noout -pubkey | openssl pkey -pubin -outform DER | base64 -w0
    security.pam.multiparty.entries = { };
  };
}
