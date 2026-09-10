# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# To test yubikey auth in the vm, get your yubikeys product ids and then run:
# nix run -L .\#run-vm -- -usb -device usb-host,vendorid=0x1050,productid=0x0407 -device usb-host,vendorid=0x1050,productid=0x0116
{
  lib,
  config,
  ...
}:
let
  hasEntries = config.security.pam.multiparty.entries != { };
  replaceUnix = {
    multipartyAuth = true;
    unixAuth = false;
  };
in
{
  security.pam.multiparty = {
    enable = lib.mkDefault true;
    # One card per group is required at login. Override with a single
    # group (e.g. `groups = [ "A" ];`) for test setups with one YubiKey.
    groups = lib.mkDefault [
      "A"
      "B"
    ];
    control = "sufficient";
  };

  security.pam.services = lib.mkIf hasEntries {
    greetd = replaceUnix;
    login = replaceUnix;
    su = replaceUnix;
  };

  users.allowNoPasswordLogin = hasEntries;

  # Bootstrap: with no entries the user has no password by default.
  # Set an empty initial password so the build doesn't fail on the
  # "locked out" assertion; operators are expected to set a real
  # password or enrol cards before production use.
  users.users.user.initialHashedPassword = lib.mkIf (!hasEntries) "";
}
