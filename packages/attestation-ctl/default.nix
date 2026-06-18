# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  writers,
}:
writers.writePython3Bin "attestation-ctl" {
  flakeIgnore = [ ];
} (builtins.readFile ./attestation-ctl.py)
