# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib, pkgs }:

pkgs.writeShellApplication {
  name = "keylime-git-clone";

  runtimeInputs = [ pkgs.gitMinimal ];

  text = ''
    set -euo pipefail

    CERT=/run/keylime-git/client-cert.pem
    KEY=/run/keylime-git/client-key.pem
    CA=/run/keylime-git/ca-cert.pem

    die()  { echo "keylime-git-clone: error: $*" >&2; exit 1; }

    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cert=*) CERT="''${1#--cert=}"; shift ;;
        --key=*)  KEY="''${1#--key=}";   shift ;;
        --ca=*)   CA="''${1#--ca=}";     shift ;;
        *)        POSITIONAL+=("$1"); shift ;;
      esac
    done

    [[ ''${#POSITIONAL[@]} -ge 1 ]] || die "usage: keylime-git-clone [--cert=] [--key=] [--ca=] <url> [dest]"

    URL="''${POSITIONAL[0]}"
    REST=("''${POSITIONAL[@]:1}")

    for f in "$CERT" "$KEY" "$CA"; do
      [[ -f "$f" ]] || die "required file not found: $f"
    done

    exec git \
      -c "http.sslCert=''${CERT}" \
      -c "http.sslKey=''${KEY}" \
      -c "http.sslCAInfo=''${CA}" \
      clone "$URL" "''${REST[@]}"
  '';

  meta = {
    description = "git-clone wrapper for TPM-attested builder machines";
    mainProgram = "keylime-git-clone";
  };
}
