# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Python unit tests for measured boot policy.
#
# Both measured-boot-library and keylime-measured-boot-policy run
# their tests via pytestCheckHook in the package's checkPhase.
# This file exposes the policy package build as a flake check so
# that `nix flake check` triggers the tests.
{
  pkgs,
  keylimePackage,
}:
{
  # Building the package triggers pytestCheckHook, which runs
  # test_measured_boot_policy.py against the keylime MBA framework.
  policyTests =
    (pkgs.callPackage ../packages/keylime-measured-boot-policy {
      keylime = keylimePackage;
    }).package;
}
