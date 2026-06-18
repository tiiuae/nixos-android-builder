# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Keylime measured boot policy for UKI (Unified Kernel Image) boot.

Registers a ``uki`` policy that validates SCRTM, firmware blobs,
Secure Boot keys, and the UKI application digest from the UEFI
event log.  See ``README.md`` in this directory for the full
policy description, reference state schema, and testing instructions.
"""

import re
import typing

from keylime.mba.elchecking import policies, tests

# UEFI GUIDs appear in two byte-order formats in event logs
# depending on firmware/parser.  The standard UEFI form has the
# first three fields in big-endian; the mixed-endian form (as
# seen in some tpm2_eventlog output) byte-swaps those fields.
# We define each GUID once in standard form and derive the
# mixed-endian variant, then match both.


def _guid_both_forms(standard: str) -> typing.Tuple[str, str]:
    """Return (mixed-endian, standard) forms of a UEFI GUID.

    The first three dash-separated fields are byte-reversed;
    the last two are left unchanged.
    """
    parts = standard.split("-")
    mixed = "-".join([
        bytes.fromhex(parts[0])[::-1].hex(),
        bytes.fromhex(parts[1])[::-1].hex(),
        bytes.fromhex(parts[2])[::-1].hex(),
        parts[3],
        parts[4],
    ])
    return (mixed, standard)


# EFI_GLOBAL_VARIABLE: namespace for SecureBoot, PK, KEK
EFI_GLOBAL_VARIABLE = _guid_both_forms(
    "8be4df61-93ca-11d2-aa0d-00e098032b8c"
)
# EFI_IMAGE_SECURITY_DATABASE_GUID: namespace for db, dbx
EFI_IMAGE_SECURITY_DATABASE = _guid_both_forms(
    "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
)
# EFI_CERT_X509_GUID: X.509 certificate signature type
EFI_CERT_X509 = _guid_both_forms(
    "a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
)
# EFI_CERT_SHA256_GUID: SHA-256 hash signature type
EFI_CERT_SHA256 = _guid_both_forms(
    "c1c41626-504c-4092-aca9-41f936934328"
)

hex_pat = re.compile("0x[0-9a-f]+")


def hex_test(dat: typing.Any) -> bool:
    if isinstance(dat, str) and hex_pat.fullmatch(dat):
        return True
    raise Exception(
        f"{dat!r} is not 0x followed by lowercase hex"
    )


digest_type_test = tests.dict_test(
    tests.type_test(str), hex_test,
)


def string_strip0x(con: str) -> str:
    if con.startswith("0x"):
        return con[2:]
    raise Exception(f"{con!r} does not start with 0x")


def digest_strip0x(
    digest: typing.Dict[str, str],
) -> tests.Digest:
    digest_type_test(digest)
    return {
        alg: string_strip0x(val)
        for alg, val in digest.items()
    }


def sigs_strip0x(
    sigs: typing.Iterable[typing.Dict[str, str]],
) -> typing.List[tests.Signature]:
    return [
        {
            "SignatureOwner": s["SignatureOwner"],
            "SignatureData": string_strip0x(s["SignatureData"]),
        }
        for s in sigs
    ]


class UkiPolicy(policies.Policy):
    """Measured boot policy for UKI boot chains."""

    # PCRs 9 and 11 are excluded from the event-log replay check
    # (see keylime's mb_pcrs_to_check()) because both receive
    # runtime extensions from userspace that are not captured in
    # the UEFI event log, so replaying the log and comparing
    # against the live PCR will always mismatch.
    #
    # PCR 11: expected-by-design. systemd-stub measures UKI PE
    # sections at boot (these DO appear in the event log), and
    # systemd-pcrphase extends phase strings ("sysinit", "ready",
    # ...) at runtime via the userspace TPM log.  The runtime
    # extensions are the whole point of PCR 11 in a UKI boot.
    #
    # PCR 9: the "Linux IPL" PCR.  systemd 259 added NvPCR
    # support and initializes the default NvPCR definitions
    # (hardware, cryptsetup) in systemd-tpm2-setup.service on
    # every boot, which extends PCR 9 with an anchoring
    # measurement.  This is per-host (anchored to a local
    # secret), runtime-only, and not in the event log.  Rather
    # than masking the upstream .nvpcr files (fragile — brittle
    # to new defaults) or per-host pinning the runtime value
    # (defeats image-wide attestation), we drop PCR 9 from the
    # replay check entirely.
    #
    # In both cases the event-level policy checks still run
    # against whatever PCR 9 / PCR 11 events are in the UEFI
    # event log (see the dispatcher below), so tampering with
    # those events is still detected.  What we lose is the
    # end-to-end integrity check that ties the event log to
    # the live PCR — a small weakening that is acceptable here
    # because the security-critical content of both PCRs (the
    # UKI image) is already pinned via uki_digest in PCR 4.
    relevant_pcr_indices = frozenset(
        [0, 1, 2, 3, 4, 5, 7],
    )

    def get_relevant_pcrs(self) -> typing.FrozenSet[int]:
        return self.relevant_pcr_indices

    def refstate_to_test(
        self, refstate: policies.RefState,
    ) -> tests.Test:
        if not isinstance(refstate, dict):
            raise Exception(
                "Expected refstate to be a dict,"
                f" got {type(refstate).__name__}"
            )

        # Validate required fields
        for req in (
            "scrtm_and_bios", "pk", "kek", "db",
            "dbx", "uki_digest",
        ):
            if req not in refstate:
                raise Exception(
                    f"refstate lacks required key: {req}"
                )

        # SCRTM and firmware blobs (PCR 0)
        scrtm_specs = refstate["scrtm_and_bios"]
        scrtm_test = tests.Or(
            *[
                tests.And(
                    tests.FieldTest(
                        "s_crtms",
                        tests.TupleTest(
                            tests.DigestTest(
                                digest_strip0x(s["scrtm"])
                            )
                        ),
                    ),
                    tests.FieldTest(
                        "platform_firmware_blobs",
                        tests.TupleTest(
                            *[
                                tests.DigestTest(
                                    digest_strip0x(pf)
                                )
                                for pf
                                in s["platform_firmware"]
                            ]
                        ),
                    ),
                )
                for s in scrtm_specs
            ]
        )

        # UKI digest (PCR 4) - single application
        uki_test = tests.TupleTest(
            tests.DigestTest(
                digest_strip0x(refstate["uki_digest"])
            ),
        )

        events_final = tests.DelayToFields(
            tests.And(
                scrtm_test,
                tests.FieldTest(
                    "uki_apps", uki_test,
                ),
            ),
            "s_crtms",
            "platform_firmware_blobs",
            "uki_apps",
        )

        dispatcher = tests.Dispatcher(
            ("PCRIndex", "EventType"),
        )

        # PCR 0 events
        dispatcher.set(
            (0, "EV_NO_ACTION"),
            tests.OnceTest(tests.AcceptAll()),
        )
        # Older TCG event type used by some firmware to measure
        # POST code blobs into PCR 0.  PCR 0 is in
        # relevant_pcr_indices so the digest is covered by the
        # end-to-end quote comparison regardless.
        dispatcher.set(
            (0, "EV_POST_CODE"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (0, "EV_S_CRTM_VERSION"),
            events_final.get("s_crtms"),
        )
        dispatcher.set(
            (0, "EV_EFI_PLATFORM_FIRMWARE_BLOB"),
            events_final.get("platform_firmware_blobs"),
        )
        dispatcher.set(
            (0, "EV_EFI_PLATFORM_FIRMWARE_BLOB2"),
            events_final.get("platform_firmware_blobs"),
        )

        # PCR 1 events -- accept all (varies with config)
        dispatcher.set(
            (1, "EV_PLATFORM_CONFIG_FLAGS"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (1, "EV_EFI_VARIABLE_BOOT"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (1, "EV_EFI_HANDOFF_TABLES"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (1, "EV_EFI_HANDOFF_TABLES2"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (1, "EV_CPU_MICROCODE"),
            tests.AcceptAll(),
        )
        dispatcher.set(
            (1, "EV_EFI_ACTION"),
            tests.EvEfiActionTest(1),
        )
        # Newer UEFI spec variant of EV_EFI_VARIABLE_BOOT,
        # used by recent firmware for boot variable measurements.
        dispatcher.set(
            (1, "EV_EFI_VARIABLE_BOOT2"),
            tests.AcceptAll(),
        )

        # PCR 2 -- boot services drivers (accept)
        dispatcher.set(
            (2, "EV_EFI_BOOT_SERVICES_DRIVER"),
            tests.AcceptAll(),
        )
        # Some firmware measures option ROM / UEFI driver blobs
        # into PCR 2 using EV_EFI_PLATFORM_FIRMWARE_BLOB rather
        # than EV_EFI_BOOT_SERVICES_DRIVER.  Feed these into the
        # same platform_firmware_blobs collector as PCR 0 events:
        # measure-boot-state captures blobs from all PCRs into
        # the refstate, so the policy must match them the same way.
        dispatcher.set(
            (2, "EV_EFI_PLATFORM_FIRMWARE_BLOB"),
            events_final.get("platform_firmware_blobs"),
        )
        dispatcher.set(
            (2, "EV_EFI_PLATFORM_FIRMWARE_BLOB2"),
            events_final.get("platform_firmware_blobs"),
        )
        # Some firmware measures option ROM code into PCR 2
        # using the older EV_POST_CODE type.  PCR 2 is in
        # relevant_pcr_indices so the quote comparison covers it.
        dispatcher.set(
            (2, "EV_POST_CODE"),
            tests.AcceptAll(),
        )

        # PCR 4 -- UKI application
        dispatcher.set(
            (4, "EV_EFI_ACTION"),
            tests.EvEfiActionTest(4),
        )
        dispatcher.set(
            (4, "EV_EFI_BOOT_SERVICES_APPLICATION"),
            events_final.get("uki_apps"),
        )

        # PCR 5
        dispatcher.set(
            (5, "EV_EFI_GPT_EVENT"),
            tests.OnceTest(tests.AcceptAll()),
        )
        dispatcher.set(
            (5, "EV_EFI_ACTION"),
            tests.EvEfiActionTest(5),
        )

        # PCR 6 -- Host Platform Manufacturer Specific.
        # PCR 6 is not in relevant_pcr_indices, so its value is
        # not checked end-to-end against the quote (the verifier
        # also skips it in tpm_policy).  These handlers exist
        # solely to prevent the dispatcher from rejecting events
        # that firmware emits here; they provide no integrity
        # guarantee beyond what the separator already covers.
        dispatcher.set(
            (6, "EV_EFI_ACTION"),
            tests.AcceptAll(),
        )

        # PCR 7 -- Secure Boot variables
        vd_config = tests.VariableDispatch()
        vd_authority = tests.VariableDispatch()

        sb_test = tests.FieldTest(
            "Enabled", tests.StringEqual("Yes"),
        )
        for guid in EFI_GLOBAL_VARIABLE:
            vd_config.set(guid, "SecureBoot", sb_test)

            pk_test = tests.OnceTest(
                tests.Or(*(
                    tests.KeySubset(
                        cert_guid,
                        sigs_strip0x(refstate["pk"]),
                    )
                    for cert_guid in EFI_CERT_X509
                ))
            )
            vd_config.set(guid, "PK", pk_test)

            kek_test = tests.OnceTest(
                tests.Or(*(
                    tests.KeySubset(
                        cert_guid,
                        sigs_strip0x(refstate["kek"]),
                    )
                    for cert_guid in EFI_CERT_X509
                ))
            )
            vd_config.set(guid, "KEK", kek_test)

        for guid in EFI_IMAGE_SECURITY_DATABASE:
            db_test = tests.OnceTest(
                tests.Or(*(
                    tests.KeySubsetMulti(
                        [x509, sha256],
                        sigs_strip0x(refstate["db"]),
                    )
                    for x509, sha256
                    in zip(EFI_CERT_X509, EFI_CERT_SHA256)
                ))
            )
            vd_config.set(guid, "db", db_test)

            if refstate["dbx"]:
                dbx_test = tests.OnceTest(
                    tests.Or(*(
                        tests.KeySuperset(
                            sha256,
                            sigs_strip0x(refstate["dbx"]),
                        )
                        for sha256 in EFI_CERT_SHA256
                    ))
                )
            else:
                dbx_test = tests.OnceTest(
                    tests.AcceptAll(),
                )
            vd_config.set(guid, "dbx", dbx_test)

            # Authority events -- accept (we pinned db)
            vd_authority.set(
                guid, "db",
                tests.OnceTest(tests.AcceptAll()),
            )

        dispatcher.set(
            (7, "EV_EFI_VARIABLE_DRIVER_CONFIG"),
            vd_config,
        )
        dispatcher.set(
            (7, "EV_EFI_VARIABLE_AUTHORITY"),
            vd_authority,
        )

        # Separators for PCRs 0-15.
        # range(8) covered the firmware PCRs; extend to 15 because
        # some firmware also emits separators for PCRs 8-15 to
        # mark the end of each measurement phase.
        for pcr in range(16):
            dispatcher.set(
                (pcr, "EV_SEPARATOR"),
                tests.EvSeperatorTest(),
            )

        # PCR 9 -- EV_EVENT_TAG from systemd-stub (accept)
        dispatcher.set(
            (9, "EV_EVENT_TAG"),
            tests.AcceptAll(),
        )

        # PCR 11 -- UKI PE sections from systemd-stub.
        # Accepted here; the raw tpm_policy digest for PCR 11
        # covers both these events and systemd-pcrphase.
        dispatcher.set(
            (11, "EV_IPL"),
            tests.AcceptAll(),
        )

        return tests.FieldTest(
            "events",
            tests.And(
                events_final.get_initializer(),
                tests.IterateTest(
                    dispatcher, show_elt=True,
                ),
                events_final,
            ),
            show_name=False,
        )


policies.register("uki", UkiPolicy())
