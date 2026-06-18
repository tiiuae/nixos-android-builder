# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Measured boot policy for keylime (UKI boot chain).
#
# Provides:
# - policyPath: directory containing the policy module, to be added to
#   PYTHONPATH so the verifier can import it via measured_boot_imports.
{
  python3Packages,
  keylime,
}:
let
  package = python3Packages.buildPythonPackage {
    pname = "keylime-measured-boot-policy";
    version = "0.1.0";
    format = "pyproject";

    src = ./.;

    build-system = [ python3Packages.setuptools ];

    nativeCheckInputs = [
      python3Packages.pytestCheckHook
      keylime
    ];
    # keylime's mba.elchecking is needed at test time (and at import
    # time), but is not a build/runtime dependency — the verifier
    # provides it via its own PYTHONPATH at runtime.
    preCheck = ''
      export PYTHONPATH="${keylime}/${python3Packages.python.sitePackages}:$PYTHONPATH"
    '';
  };
in
{
  inherit package;

  # Directory containing the policy module. Add to the verifier's
  # PYTHONPATH and reference as "measured_boot_policy" in
  # measured_boot_imports.
  policyPath = "${package}/${python3Packages.python.sitePackages}";
}
