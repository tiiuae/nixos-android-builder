# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for the measured boot state library.

Tests refstate generation, PCR replay, and refstate diffing
using synthetic event data (no tpm2_eventlog required).
"""

import hashlib
import json
import pytest

from measured_boot_state import (
    create_refstate,
    diff_refstates,
    event_to_sha256,
    get_keys,
    get_platform_firmware,
    get_scrtm,
    get_uki_digest,
    parse_userspace_log,
    replay_pcrs,
)
DIGEST_AA = "aa" * 32
DIGEST_BB = "bb" * 32
DIGEST_CC = "cc" * 32
def make_event(
    pcr, event_type, sha256_digest,
    event_data=None,
):
    ev = {
        "PCRIndex": pcr,
        "EventType": event_type,
        "Digests": [
            {
                "AlgorithmId": "sha256",
                "Digest": sha256_digest,
            },
        ],
    }
    if event_data is not None:
        ev["Event"] = event_data
    return ev
def make_separator(pcr):
    return make_event(pcr, "EV_SEPARATOR", "00" * 32)
def make_fw_app(pcr, digest, device_path=""):
    """EV_EFI_BOOT_SERVICES_APPLICATION event."""
    return make_event(
        pcr,
        "EV_EFI_BOOT_SERVICES_APPLICATION",
        digest,
        event_data={"DevicePath": device_path},
    )

class TestEventToSha256:
    def test_extracts_sha256(self):
        ev = make_event(0, "EV_S_CRTM_VERSION", DIGEST_AA)
        assert event_to_sha256(ev) == {
            "sha256": f"0x{DIGEST_AA}",
        }

    def test_no_sha256(self):
        ev = {
            "Digests": [
                {
                    "AlgorithmId": "sha1",
                    "Digest": "aa" * 20,
                },
            ],
        }
        assert event_to_sha256(ev) == {}

    def test_no_digests(self):
        assert event_to_sha256({}) == {}

class TestGetScrtm:
    def test_finds_scrtm(self):
        events = [
            make_event(
                0, "EV_S_CRTM_VERSION", DIGEST_AA,
            ),
        ]
        assert get_scrtm(events) == {
            "scrtm": {"sha256": f"0x{DIGEST_AA}"},
        }

    def test_no_scrtm(self):
        assert get_scrtm([]) == {}

class TestGetPlatformFirmware:
    def test_collects_blobs(self):
        events = [
            make_event(
                0, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
                DIGEST_AA,
            ),
            make_event(
                0, "EV_EFI_PLATFORM_FIRMWARE_BLOB2",
                DIGEST_BB,
            ),
        ]
        result = get_platform_firmware(events)
        assert len(result["platform_firmware"]) == 2

    def test_empty(self):
        result = get_platform_firmware([])
        assert result == {"platform_firmware": []}

class TestGetUkiDigest:
    def test_single_uki_app(self):
        events = [
            make_separator(4),
            make_fw_app(4, DIGEST_AA),
        ]
        result = get_uki_digest(events)
        assert result == {"sha256": f"0x{DIGEST_AA}"}

    def test_filters_enriched_firmware_apps(self):
        """FvVol/FvFile DevicePath (libefivar) is filtered."""
        fw_dp = (
            "FvVol(12345678-1234-1234-1234-123456789abc)"
            "/FvFile(abcdef01-2345-6789-abcd-ef0123456789)"
        )
        events = [
            make_fw_app(4, DIGEST_BB, device_path=fw_dp),
            make_separator(4),
            make_fw_app(4, DIGEST_AA),
        ]
        result = get_uki_digest(events)
        assert result == {"sha256": f"0x{DIGEST_AA}"}

    def test_ignores_pcr2_events(self):
        """PCR 2 EV_EFI_BOOT_SERVICES_APPLICATION events
        (if any) are ignored."""
        events = [
            make_fw_app(2, DIGEST_BB),
            make_separator(4),
            make_fw_app(4, DIGEST_AA),
        ]
        result = get_uki_digest(events)
        assert result == {"sha256": f"0x{DIGEST_AA}"}

    def test_multiple_non_firmware_apps_warns(self):
        """Multiple non-firmware PCR 4 apps returns first
        (and warns)."""
        events = [
            make_separator(4),
            make_fw_app(4, DIGEST_AA),
            make_fw_app(4, DIGEST_BB),
        ]
        result = get_uki_digest(events)
        assert result == {"sha256": f"0x{DIGEST_AA}"}

    def test_empty(self):
        assert get_uki_digest([]) == {}

class TestGetKeys:
    def test_extracts_keys(self):
        events = [{
            "EventType": "EV_EFI_VARIABLE_DRIVER_CONFIG",
            "Event": {
                "UnicodeName": "PK",
                "VariableData": [{
                    "Keys": [{
                        "SignatureOwner": "owner-1",
                        "SignatureData": "aabb",
                    }],
                }],
            },
        }]
        result = get_keys(events)
        assert len(result["pk"]) == 1
        assert result["pk"][0]["SignatureOwner"] == "owner-1"
        assert result["pk"][0]["SignatureData"] == "0xaabb"

    def test_ignores_non_key_events(self):
        events = [{
            "EventType": "EV_S_CRTM_VERSION",
            "Event": {},
        }]
        result = get_keys(events)
        for key in ("pk", "kek", "db", "dbx"):
            assert result[key] == []

class TestParseUserspaceLog:
    def test_parses_json_seq(self, tmp_path):
        log = tmp_path / "tpm2-measure.log"
        # RFC 7464: each record prefixed with 0x1E
        record = {
            "pcr": 9,
            "digests": [
                {
                    "hashAlg": "sha256",
                    "digest": DIGEST_AA,
                },
            ],
            "content_type": "systemd",
            "content": {
                "string": "test",
            },
        }
        log.write_text(
            f"\x1e{json.dumps(record)}\n"
        )
        events = parse_userspace_log(str(log))
        assert len(events) == 1
        assert events[0]["PCRIndex"] == 9
        assert events[0]["Digests"][0][
            "AlgorithmId"
        ] == "sha256"
        assert events[0]["Digests"][0][
            "Digest"
        ] == DIGEST_AA

    def test_multiple_records(self, tmp_path):
        log = tmp_path / "tpm2-measure.log"
        lines = ""
        for pcr, digest in [
            (11, DIGEST_AA), (9, DIGEST_BB),
        ]:
            record = {
                "pcr": pcr,
                "digests": [{
                    "hashAlg": "sha256",
                    "digest": digest,
                }],
            }
            lines += f"\x1e{json.dumps(record)}\n"
        log.write_text(lines)
        events = parse_userspace_log(str(log))
        assert len(events) == 2
        assert events[0]["PCRIndex"] == 11
        assert events[1]["PCRIndex"] == 9

    def test_skips_records_without_pcr(self, tmp_path):
        log = tmp_path / "tpm2-measure.log"
        record = {
            "nv_index": 42,
            "digests": [{
                "hashAlg": "sha256",
                "digest": DIGEST_AA,
            }],
        }
        log.write_text(
            f"\x1e{json.dumps(record)}\n"
        )
        events = parse_userspace_log(str(log))
        assert len(events) == 0

    def test_missing_file(self):
        events = parse_userspace_log(
            "/nonexistent/path"
        )
        assert events == []


class TestReplayPcrs:
    def test_single_event(self):
        events = [
            make_event(0, "EV_S_CRTM_VERSION", DIGEST_AA),
        ]
        pcrs = replay_pcrs(events)
        expected = hashlib.sha256(
            b"\x00" * 32 + bytes.fromhex(DIGEST_AA)
        ).hexdigest()
        assert pcrs[0] == expected

    def test_multiple_extends(self):
        events = [
            make_event(0, "EV_S_CRTM_VERSION", DIGEST_AA),
            make_event(
                0, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
                DIGEST_BB,
            ),
        ]
        pcrs = replay_pcrs(events)
        step1 = hashlib.sha256(
            b"\x00" * 32 + bytes.fromhex(DIGEST_AA)
        ).digest()
        step2 = hashlib.sha256(
            step1 + bytes.fromhex(DIGEST_BB)
        ).hexdigest()
        assert pcrs[0] == step2

    def test_separate_pcrs(self):
        events = [
            make_event(0, "EV_S_CRTM_VERSION", DIGEST_AA),
            make_event(4, "EV_EFI_ACTION", DIGEST_BB),
        ]
        pcrs = replay_pcrs(events)
        assert 0 in pcrs
        assert 4 in pcrs

    def test_empty(self):
        assert replay_pcrs([]) == {}

    def test_with_userspace_events(self):
        """Userspace events extend after UEFI events."""
        uefi_events = [
            make_event(
                9, "EV_EVENT_TAG", DIGEST_AA,
            ),
        ]
        userspace_events = [
            {
                "PCRIndex": 9,
                "Digests": [{
                    "AlgorithmId": "sha256",
                    "Digest": DIGEST_BB,
                }],
            },
        ]
        pcrs = replay_pcrs(uefi_events, userspace_events)
        step1 = hashlib.sha256(
            b"\x00" * 32 + bytes.fromhex(DIGEST_AA)
        ).digest()
        step2 = hashlib.sha256(
            step1 + bytes.fromhex(DIGEST_BB)
        ).hexdigest()
        assert pcrs[9] == step2

    def test_userspace_only(self):
        """Userspace-only events still produce values."""
        userspace_events = [
            {
                "PCRIndex": 11,
                "Digests": [{
                    "AlgorithmId": "sha256",
                    "Digest": DIGEST_AA,
                }],
            },
        ]
        pcrs = replay_pcrs([], userspace_events)
        expected = hashlib.sha256(
            b"\x00" * 32 + bytes.fromhex(DIGEST_AA)
        ).hexdigest()
        assert pcrs[11] == expected

class TestCreateRefstate:
    def test_has_required_keys(self):
        events = [
            make_event(
                0, "EV_S_CRTM_VERSION", DIGEST_AA,
            ),
            make_event(
                0, "EV_EFI_PLATFORM_FIRMWARE_BLOB",
                DIGEST_BB,
            ),
            make_separator(4),
            make_fw_app(4, DIGEST_CC),
        ]
        rs = create_refstate(events)
        for key in (
            "scrtm_and_bios", "pk", "kek", "db",
            "dbx", "uki_digest",
        ):
            assert key in rs

    def test_no_userspace_digests_by_default(self):
        events = [
            make_event(
                0, "EV_S_CRTM_VERSION", DIGEST_AA,
            ),
            make_separator(4),
            make_fw_app(4, DIGEST_CC),
        ]
        rs = create_refstate(events)
        assert "userspace_digests" not in rs

    def test_includes_userspace_digests(self):
        events = [
            make_event(
                0, "EV_S_CRTM_VERSION", DIGEST_AA,
            ),
            make_separator(4),
            make_fw_app(4, DIGEST_CC),
        ]
        userspace_events = [
            {
                "PCRIndex": 11,
                "Digests": [{
                    "AlgorithmId": "sha256",
                    "Digest": DIGEST_BB,
                }],
            },
        ]
        rs = create_refstate(events, userspace_events)
        assert "userspace_digests" in rs
        assert len(rs["userspace_digests"]) == 1
        assert rs["userspace_digests"][0] == {
            "pcr": 11,
            "digest": DIGEST_BB,
            "algorithm": "sha256",
        }

class TestDiffRefstates:
    def _make_rs(self, uki="aa" * 32):
        return {
            "scrtm_and_bios": [{
                "scrtm": {"sha256": f"0x{uki}"},
                "platform_firmware": [],
            }],
            "pk": [], "kek": [], "db": [], "dbx": [],
            "uki_digest": {"sha256": f"0x{uki}"},
        }

    def test_identical(self):
        rs = self._make_rs()
        diff = diff_refstates(rs, rs)
        for v in diff.values():
            assert v is None

    def test_uki_changed(self):
        old = self._make_rs("aa" * 32)
        new = self._make_rs("bb" * 32)
        diff = diff_refstates(old, new)
        assert diff["uki_digest"] is not None
