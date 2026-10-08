# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  # Name our system. Image file names and metadata is derived from this.
  system.name = "android-builder";

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

  nixosAndroidBuilder = {
    debug = false;

    artifactStorage = {
      enable = true;
      contents = [
        "target/product/*"
        "source_measurement.txt"
      ];
    };
    credentialStorage.enable = true;

    unattended.enable = true;

    build = {
      branches = [
        "android-latest-release"
      ];
      repoManifestUrl = "https://android.googlesource.com/platform/manifest";
      lunchTarget = "aosp_cf_x86_64_only_phone-aosp_current-eng";
      userName = "CI User";
      userEmail = "ci@example.com";
    };
  };
}
