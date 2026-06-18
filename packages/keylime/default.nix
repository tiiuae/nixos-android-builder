# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  python3Packages,
  fetchFromGitHub,
  gnupg,
  tpm2-tools,
  efivar,
}:
let
  # Unreleased master commit past v7.14.1 — needed as the base for our
  # local patch series.  All four patches below target this revision.
  version = "7.14.1-unstable-2026-04-02";
  rev = "4c2a0c6ca84c87667c9a19605ae767e1755ac713";
in
python3Packages.buildPythonApplication {
  pname = "keylime";
  format = "setuptools";
  inherit version;

  src = fetchFromGitHub {
    owner = "keylime";
    repo = "keylime";
    inherit rev;
    hash = "sha256-RLmTn/YYWs6BJnnfMj09MAwy3DKQqR0qVohNXhL65/c=";
  };

  build-system = with python3Packages; [
    setuptools
    jinja2
  ];

  dependencies = with python3Packages; [
    cryptography
    tornado
    pyzmq
    pyyaml
    requests
    sqlalchemy
    alembic
    packaging
    psutil
    lark
    pyasn1
    pyasn1-modules
    gpgme
    jinja2
    jsonschema
  ];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    "${lib.makeBinPath [
      gnupg
      tpm2-tools
    ]}"
    # efivar is needed by keylime for UEFI event log parsing
    "--prefix"
    "LD_LIBRARY_PATH"
    ":"
    "${lib.getLib efivar}/lib"
  ];

  patches = [
    # https://github.com/keylime/keylime/pull/1878
    # Check tpm2_eventlog exit code instead of stderr (benign warnings
    # from UKI EV_IPL events broke all measured boot attestation).
    ./0001-elparsing-check-tpm2_eventlog-exit-code-instead-of-s.patch
    # https://github.com/keylime/keylime/pull/1879
    # Use the policy's get_relevant_pcrs() for event log PCR replay
    # (PCR 11 has runtime extensions from systemd-pcrphase).
    ./0002-tpm-use-policy-s-relevant-PCRs-for-event-log-verific.patch
    # https://github.com/keylime/keylime/issues/1880
    # Tracked upstream as an issue, no PR yet.  The verifier maps
    # `mbpolicies` and `verifiermain` to two independent SQLAlchemy
    # ORM classes (declarative_base in db/ versus the model framework
    # in models/), with separate identity maps that cannot see each
    # other's writes.  Both patches issue raw SQL to bypass the cache
    # for fields that are read or written across the mapping boundary.
    # Until upstream consolidates to a single mapping per table, this
    # is the only mechanism that works.
    ./0003-tpm_engine-bypass-dual-mapping-cache-for-uefi_ref_st.patch
    ./0004-tpm_engine-bypass-dual-mapping-cache-for-accept_atte.patch
  ];

  doCheck = false;

  meta = {
    description = "TPM-based key bootstrapping and system integrity measurement system";
    homepage = "https://keylime.dev";
    changelog = "https://github.com/keylime/keylime/releases/tag/v${version}";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
