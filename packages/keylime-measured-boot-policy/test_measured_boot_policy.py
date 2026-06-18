# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for the UKI measured boot policy.

Tests the policy against synthetic event logs to verify it
accepts valid boots and rejects tampered ones, without
requiring a full NixOS VM test.
"""

import hashlib
import pytest

from keylime.mba.elchecking import policies

# Importing the module registers the "uki" policy
import measured_boot_policy  # noqa: F401

# --------------- constants ---------------

# Standard-form UEFI GUIDs (matching index 1 in the policy)
EFI_GLOBAL = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
EFI_IMAGE_SEC_DB = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
EFI_CERT_X509 = "a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
EFI_CERT_SHA256 = "c1c41626-504c-4092-aca9-41f936934328"

# Fake hex digests (64 hex chars = 32 bytes)
SCRTM_DIGEST = "aa" * 32
FW_BLOB_1_DIGEST = "bb" * 32
FW_BLOB_2_DIGEST = "bc" * 32
UKI_DIGEST = "cc" * 32

# Fake Secure Boot key material
KEY_OWNER = "12345678-1234-1234-1234-123456789abc"
PK_SIG_DATA = "dd" * 64
KEK_SIG_DATA = "ee" * 64
DB_SIG_DATA = "ff" * 64
DBX_SIG_DATA = "11" * 32


# --------------- helpers ---------------


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_digests(sha256_hex_val: str) -> list:
    return [
        {"AlgorithmId": "sha256", "Digest": sha256_hex_val},
    ]


def make_event(
    pcr: int, event_type: str,
    digests: list, event_data=None,
) -> dict:
    ev = {
        "PCRIndex": pcr,
        "EventType": event_type,
        "Digests": digests,
    }
    if event_data is not None:
        ev["Event"] = event_data
    return ev


def make_separator(pcr: int) -> dict:
    """EV_SEPARATOR with 4 null bytes."""
    val = "00000000"
    val_bytes = bytes.fromhex(val)
    return make_event(
        pcr, "EV_SEPARATOR",
        make_digests(sha256_hex(val_bytes)),
        event_data=val,
    )


def make_efi_action(pcr: int, action: str) -> dict:
    return make_event(
        pcr, "EV_EFI_ACTION",
        make_digests(sha256_hex(action.encode())),
        event_data=action,
    )


def make_var_config(
    guid: str, name: str, var_data,
) -> dict:
    return make_event(
        7, "EV_EFI_VARIABLE_DRIVER_CONFIG",
        make_digests("00" * 32),  # digest not checked
        event_data={
            "VariableName": guid,
            "UnicodeName": name,
            "VariableData": var_data,
        },
    )


def make_var_authority(
    guid: str, name: str,
) -> dict:
    return make_event(
        7, "EV_EFI_VARIABLE_AUTHORITY",
        make_digests("00" * 32),
        event_data={
            "VariableName": guid,
            "UnicodeName": name,
            "VariableData": {},
        },
    )


def make_key_list(sig_type, owner, sig_data):
    """Build a VariableData list with one signature."""
    return [{
        "SignatureType": sig_type,
        "Keys": [
            {
                "SignatureOwner": owner,
                "SignatureData": sig_data,
            },
        ],
    }]


# --------------- fixtures ---------------


def build_refstate(
    scrtm=SCRTM_DIGEST,
    fw_blobs=None,
    uki=UKI_DIGEST,
    pk_data=PK_SIG_DATA,
    kek_data=KEK_SIG_DATA,
    db_data=DB_SIG_DATA,
    dbx_data=DBX_SIG_DATA,
):
    if fw_blobs is None:
        fw_blobs = [FW_BLOB_1_DIGEST, FW_BLOB_2_DIGEST]
    return {
        "scrtm_and_bios": [{
            "scrtm": {"sha256": f"0x{scrtm}"},
            "platform_firmware": [
                {"sha256": f"0x{d}"} for d in fw_blobs
            ],
        }],
        "pk": [{
            "SignatureOwner": KEY_OWNER,
            "SignatureData": f"0x{pk_data}",
        }],
        "kek": [{
            "SignatureOwner": KEY_OWNER,
            "SignatureData": f"0x{kek_data}",
        }],
        "db": [{
            "SignatureOwner": KEY_OWNER,
            "SignatureData": f"0x{db_data}",
        }],
        "dbx": [{
            "SignatureOwner": KEY_OWNER,
            "SignatureData": f"0x{dbx_data}",
        }],
        "uki_digest": {"sha256": f"0x{uki}"},
    }


def build_eventlog(
    scrtm=SCRTM_DIGEST,
    fw_blobs=None,
    uki=UKI_DIGEST,
    pk_data=PK_SIG_DATA,
    kek_data=KEK_SIG_DATA,
    db_data=DB_SIG_DATA,
    dbx_data=DBX_SIG_DATA,
):
    if fw_blobs is None:
        fw_blobs = [FW_BLOB_1_DIGEST, FW_BLOB_2_DIGEST]

    events = []

    # --- PCR 0: SCRTM + firmware ---
    events.append(make_event(
        0, "EV_NO_ACTION",
        make_digests("00" * 32),
    ))
    events.append(make_event(
        0, "EV_S_CRTM_VERSION",
        make_digests(scrtm),
    ))
    for d in fw_blobs:
        events.append(make_event(
            0, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
            make_digests(d),
        ))

    # --- PCR 7: Secure Boot variables ---
    events.append(make_var_config(
        EFI_GLOBAL, "SecureBoot",
        {"Enabled": "Yes"},
    ))
    events.append(make_var_config(
        EFI_GLOBAL, "PK",
        make_key_list(EFI_CERT_X509, KEY_OWNER, pk_data),
    ))
    events.append(make_var_config(
        EFI_GLOBAL, "KEK",
        make_key_list(EFI_CERT_X509, KEY_OWNER, kek_data),
    ))
    events.append(make_var_config(
        EFI_IMAGE_SEC_DB, "db",
        make_key_list(EFI_CERT_X509, KEY_OWNER, db_data),
    ))
    events.append(make_var_config(
        EFI_IMAGE_SEC_DB, "dbx",
        make_key_list(
            EFI_CERT_SHA256, KEY_OWNER, dbx_data,
        ),
    ))

    # --- Separators for PCRs 0-7 ---
    for pcr in range(8):
        events.append(make_separator(pcr))

    # --- PCR 4: EFI actions + UKI ---
    events.append(make_efi_action(
        4, "Calling EFI Application from Boot Option",
    ))
    events.append(make_event(
        4, "EV_EFI_BOOT_SERVICES_APPLICATION",
        make_digests(uki),
    ))
    events.append(make_efi_action(
        4, "Returning from EFI Application from Boot Option",
    ))

    # --- PCR 5: GPT + exit boot services ---
    events.append(make_event(
        5, "EV_EFI_GPT_EVENT",
        make_digests("00" * 32),
    ))
    events.append(make_efi_action(
        5, "Exit Boot Services Invocation",
    ))
    events.append(make_efi_action(
        5, "Exit Boot Services Returned with Success",
    ))

    # --- PCR 7: authority ---
    events.append(make_var_authority(
        EFI_IMAGE_SEC_DB, "db",
    ))

    # --- PCR 9: systemd-stub tags ---
    events.append(make_event(
        9, "EV_EVENT_TAG",
        make_digests("00" * 32),
    ))

    # --- PCR 11: UKI PE sections ---
    events.append(make_event(
        11, "EV_IPL",
        make_digests("00" * 32),
    ))

    return {"events": events}


@pytest.fixture
def policy():
    p = policies.get_policy("uki")
    assert p is not None, "uki policy not registered"
    return p


@pytest.fixture
def valid_refstate():
    return build_refstate()


@pytest.fixture
def valid_eventlog():
    return build_eventlog()


# --------------- tests ---------------


class TestPolicyRegistration:
    def test_uki_policy_registered(self):
        assert "uki" in policies.get_policy_names()

    def test_relevant_pcrs(self, policy):
        # PCRs 9 and 11 are excluded from replay because both
        # receive runtime (userspace) extensions not in the UEFI
        # event log: PCR 11 via systemd-pcrphase, PCR 9 via
        # systemd >= 259 NvPCR anchoring in
        # systemd-tpm2-setup.service.
        expected = frozenset([0, 1, 2, 3, 4, 5, 7])
        assert policy.get_relevant_pcrs() == expected


class TestPolicyAccepts:
    def test_valid_boot(self, policy, valid_refstate,
                        valid_eventlog):
        reason = policy.evaluate(
            valid_refstate, valid_eventlog,
        )
        assert reason == "", (
            f"Policy rejected valid boot: {reason}"
        )

    def test_single_firmware_blob(self, policy):
        rs = build_refstate(fw_blobs=["ab" * 32])
        el = build_eventlog(fw_blobs=["ab" * 32])
        assert policy.evaluate(rs, el) == ""

    def test_many_firmware_blobs(self, policy):
        blobs = [f"{i:02x}" * 32 for i in range(5)]
        rs = build_refstate(fw_blobs=blobs)
        el = build_eventlog(fw_blobs=blobs)
        assert policy.evaluate(rs, el) == ""

    def test_empty_dbx(self, policy):
        rs = build_refstate()
        rs["dbx"] = []
        el = build_eventlog()
        assert policy.evaluate(rs, el) == ""


class TestFirmwareVariants:
    """Policy accepts event types emitted by real firmware
    that are not present in the baseline synthetic log."""

    def test_post_code_in_pcr0(self, policy, valid_refstate):
        """Some firmware measures POST code blobs into PCR 0
        using the older EV_POST_CODE event type."""
        el = build_eventlog()
        el["events"].insert(1, make_event(
            0, "EV_POST_CODE",
            make_digests("ab" * 32),
            event_data={"BlobBase": 4289069056,
                        "BlobLength": 4980736},
        ))
        assert policy.evaluate(valid_refstate, el) == ""

    def test_efi_variable_boot2_in_pcr1(self, policy,
                                        valid_refstate):
        """Recent firmware uses EV_EFI_VARIABLE_BOOT2 in PCR 1
        instead of or alongside EV_EFI_VARIABLE_BOOT."""
        el = build_eventlog()
        el["events"].append(make_event(
            1, "EV_EFI_VARIABLE_BOOT2",
            make_digests("ab" * 32),
        ))
        assert policy.evaluate(valid_refstate, el) == ""

    def test_firmware_blob_in_pcr2(self, policy):
        """Some firmware measures option ROM blobs into PCR 2
        using EV_EFI_PLATFORM_FIRMWARE_BLOB instead of
        EV_EFI_BOOT_SERVICES_DRIVER.  The blob must be in the
        refstate since measure-boot-state captures from all PCRs."""
        pcr2_blob = "ab" * 32
        rs = build_refstate(fw_blobs=[pcr2_blob])
        el = build_eventlog(fw_blobs=[])  # no PCR 0 blobs
        el["events"].append(make_event(
            2, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
            make_digests(pcr2_blob),
            event_data={"BlobBase": 3423741648,
                        "BlobLength": 122368},
        ))
        assert policy.evaluate(rs, el) == ""

    def test_firmware_blob2_in_pcr2(self, policy):
        """Same as above for EV_EFI_PLATFORM_FIRMWARE_BLOB2."""
        pcr2_blob = "ab" * 32
        rs = build_refstate(fw_blobs=[pcr2_blob])
        el = build_eventlog(fw_blobs=[])
        el["events"].append(make_event(
            2, "EV_EFI_PLATFORM_FIRMWARE_BLOB2",
            make_digests(pcr2_blob),
            event_data={"BlobBase": 3423741648,
                        "BlobLength": 122368},
        ))
        assert policy.evaluate(rs, el) == ""

    def test_wrong_firmware_blob_in_pcr2_rejected(self,
                                                   policy):
        """A PCR 2 blob whose digest is not in the refstate
        must be rejected."""
        rs = build_refstate(fw_blobs=["ab" * 32])
        el = build_eventlog(fw_blobs=[])
        el["events"].append(make_event(
            2, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
            make_digests("00" * 32),  # wrong digest
            event_data={"BlobBase": 3423741648,
                        "BlobLength": 122368},
        ))
        assert policy.evaluate(rs, el) != ""

    def test_post_code_in_pcr2(self, policy, valid_refstate):
        """Some firmware measures option ROM code into PCR 2
        using the older EV_POST_CODE event type."""
        el = build_eventlog()
        el["events"].append(make_event(
            2, "EV_POST_CODE",
            make_digests("ab" * 32),
            event_data={"BlobBase": 983040,
                        "BlobLength": 65536},
        ))
        assert policy.evaluate(valid_refstate, el) == ""

    def test_efi_action_in_pcr6(self, policy, valid_refstate):
        """Some firmware emits EV_EFI_ACTION in PCR 6.

        PCR 6 is not in relevant_pcr_indices and is skipped by
        tpm_policy, so acceptance here provides no integrity
        guarantee; the handler just prevents the dispatcher from
        choking.
        """
        el = build_eventlog()
        el["events"].append(make_efi_action(
            6, "Ready To Boot",
        ))
        assert policy.evaluate(valid_refstate, el) == ""

    @pytest.mark.parametrize("pcr", [8, 9, 11, 14, 15])
    def test_separator_in_higher_pcrs(self, policy,
                                      valid_refstate, pcr):
        """Some firmware emits EV_SEPARATOR for PCRs beyond 7."""
        el = build_eventlog()
        el["events"].append(make_separator(pcr))
        assert policy.evaluate(valid_refstate, el) == ""


class TestPolicyRejectsUki:
    def test_wrong_uki_digest(self, policy,
                              valid_eventlog):
        rs = build_refstate(uki="00" * 32)
        reason = policy.evaluate(rs, valid_eventlog)
        assert reason != "", "Should reject wrong UKI"

    def test_missing_uki_event(self, policy,
                               valid_refstate):
        el = build_eventlog()
        el["events"] = [
            e for e in el["events"]
            if e.get("EventType")
            != "EV_EFI_BOOT_SERVICES_APPLICATION"
        ]
        reason = policy.evaluate(valid_refstate, el)
        assert reason != "", "Should reject missing UKI"


class TestPolicyRejectsScrtm:
    def test_wrong_scrtm(self, policy, valid_eventlog):
        rs = build_refstate(scrtm="00" * 32)
        reason = policy.evaluate(rs, valid_eventlog)
        assert reason != "", "Should reject wrong SCRTM"

    def test_wrong_firmware_blob(self, policy,
                                 valid_refstate):
        el = build_eventlog(
            fw_blobs=["00" * 32, FW_BLOB_2_DIGEST],
        )
        reason = policy.evaluate(valid_refstate, el)
        assert reason != "", (
            "Should reject wrong firmware blob"
        )

    def test_extra_firmware_blob(self, policy,
                                 valid_refstate):
        el = build_eventlog(
            fw_blobs=[
                FW_BLOB_1_DIGEST,
                FW_BLOB_2_DIGEST,
                "00" * 32,
            ],
        )
        reason = policy.evaluate(valid_refstate, el)
        assert reason != "", (
            "Should reject extra firmware blob"
        )


class TestPolicyRejectsKeys:
    def test_wrong_pk(self, policy, valid_eventlog):
        rs = build_refstate(pk_data="00" * 64)
        reason = policy.evaluate(rs, valid_eventlog)
        assert reason != "", "Should reject wrong PK"

    def test_wrong_kek(self, policy, valid_eventlog):
        rs = build_refstate(kek_data="00" * 64)
        reason = policy.evaluate(rs, valid_eventlog)
        assert reason != "", "Should reject wrong KEK"

    def test_wrong_db(self, policy, valid_eventlog):
        rs = build_refstate(db_data="00" * 64)
        reason = policy.evaluate(rs, valid_eventlog)
        assert reason != "", "Should reject wrong db"

    def test_secure_boot_disabled(self, policy,
                                  valid_refstate):
        el = build_eventlog()
        for e in el["events"]:
            if (e.get("EventType")
                    == "EV_EFI_VARIABLE_DRIVER_CONFIG"):
                ev = e.get("Event", {})
                if ev.get("UnicodeName") == "SecureBoot":
                    ev["VariableData"]["Enabled"] = "No"
        reason = policy.evaluate(valid_refstate, el)
        assert reason != "", (
            "Should reject disabled SecureBoot"
        )


class TestPolicyRefstateValidation:
    def test_missing_required_key(self, policy):
        rs = build_refstate()
        del rs["uki_digest"]
        with pytest.raises(Exception, match="uki_digest"):
            policy.refstate_to_test(rs)

    def test_refstate_not_dict(self, policy):
        with pytest.raises(Exception, match="dict"):
            policy.refstate_to_test("not a dict")

    def test_invalid_digest_format(self, policy):
        rs = build_refstate()
        rs["uki_digest"] = {"sha256": "no-0x-prefix"}
        with pytest.raises(Exception):
            policy.refstate_to_test(rs)
