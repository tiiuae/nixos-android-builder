# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# tpm2-tools from upstream master, for the PCR 11 EV_IPL fix
# (commit b25c9220: "tpm2_eventlog: Extend pcrs using event EV_IPL")
# which silences spurious warnings about UKI measurements in PCR 11.
# Upstream has not released a version since 5.7.
{
  tpm2-tools,
  fetchFromGitHub,
  autoreconfHook,
  autoconf-archive,
}:
let
  version = "5.7-unstable-2026-03-17";
in
tpm2-tools.overrideAttrs (old: {
  inherit version;

  src = fetchFromGitHub {
    owner = "tpm2-software";
    repo = "tpm2-tools";
    rev = "c9a5dff0dfa2a6594a204b0ccb7609dafaf31d36";
    hash = "sha256-yhJ2x/lGnSwyxEH8f/jqz0V8VjUwWrQxfAocpME+Zxk=";
  };

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    autoreconfHook
    autoconf-archive
  ];

  # The git checkout needs VERSION and src_vars.mk which are
  # normally created by ./bootstrap (not shipped in releases).
  preAutoreconf = ''
    echo "${version}" > VERSION
    # Generate source file lists for Makefile.am
    src_listvar () {
      basedir=$1; suffix=$2; var=$3
      find "$basedir" -name "$suffix" | LC_ALL=C sort | tr '\n' ' ' \
        | (printf "%s = " "$var" && cat)
      echo ""
    }
    {
      src_listvar "lib" "*.c" "LIB_C"
      src_listvar "lib" "*.h" "LIB_H"
      printf "LIB_SRC = \$(LIB_C) \$(LIB_H)\n"
      src_listvar "test/integration/tests" "*.sh" "SYSTEM_TESTS"
      printf "ALL_SYSTEM_TESTS = \$(SYSTEM_TESTS)\n"
      src_listvar "test/integration/fapi" "*.sh" "FAPI_TESTS"
      printf "ALL_FAPI_TESTS = \$(FAPI_TESTS)\n"
    } > src_vars.mk
    mkdir -p m4
  '';
})
