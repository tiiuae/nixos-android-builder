# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Measured boot reference state library.

Parses the binary UEFI event log (via ``tpm2_eventlog``) and
extracts a reference state for the UKI boot policy: SCRTM,
firmware blobs, Secure Boot keys, and UKI application digest.

Also provides PCR replay and refstate diffing for debugging
attestation mismatches.

Requires ``tpm2_eventlog`` on PATH, libefivar (for UEFI device
path decoding), and PyYAML.
"""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml

UEFI_EVENTLOG = (
    "/sys/kernel/security/tpm0/binary_bios_measurements"
)
TPM_SYSFS = "/sys/class/tpm/tpm0/pcr-sha256"
USERSPACE_TPM_LOG = (
    "/run/log/systemd/tpm2-measure.log"
)


def parse_eventlog(
    path: str,
) -> Optional[Dict[str, Any]]:
    """Parse a binary UEFI event log with tpm2_eventlog.

    Returns the parsed YAML structure, or None on failure.
    Warnings from tpm2_eventlog (e.g. about UKI's PCR 11
    EV_IPL events) are printed to stderr but not fatal.
    """
    result = subprocess.run(
        [
            "tpm2_eventlog", "--eventlog-version=2",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"tpm2_eventlog failed (rc={result.returncode}):"
            f" {result.stderr}",
            file=sys.stderr,
        )
        return None

    if result.stderr.strip():
        print(
            "tpm2_eventlog warnings:"
            f" {result.stderr.strip()}",
            file=sys.stderr,
        )

    try:
        return yaml.safe_load(result.stdout)
    except yaml.YAMLError as e:
        print(
            f"Failed to parse tpm2_eventlog YAML: {e}",
            file=sys.stderr,
        )
        return None


def event_to_sha256(
    event: Dict[str, Any],
) -> Dict[str, str]:
    """Extract the sha256 digest from an event."""
    for digest in event.get("Digests", []):
        aid = digest.get("AlgorithmId", "")
        if aid == "sha256":
            return {"sha256": f"0x{digest['Digest']}"}
    return {}


def get_scrtm(
    events: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Find the EV_S_CRTM_VERSION event."""
    for event in events:
        et = event.get("EventType", "")
        if et == "EV_S_CRTM_VERSION":
            return {"scrtm": event_to_sha256(event)}
    return {}


def get_platform_firmware(
    events: List[Dict[str, Any]],
) -> Dict[str, List[Dict[str, str]]]:
    """Get firmware blob digests."""
    out = []
    for event in events:
        et = event.get("EventType", "")
        if et in (
            "EV_EFI_PLATFORM_FIRMWARE_BLOB",
            "EV_EFI_PLATFORM_FIRMWARE_BLOB2",
        ):
            out.append(event_to_sha256(event))
    return {"platform_firmware": out}


def get_keys(
    events: List[Dict[str, Any]],
) -> Dict[str, List[Dict[str, str]]]:
    """Get Secure Boot key signatures."""
    out: Dict[str, List[Dict[str, str]]] = {
        "pk": [], "kek": [], "db": [], "dbx": [],
    }
    for event in events:
        et = event.get("EventType", "")
        if et != "EV_EFI_VARIABLE_DRIVER_CONFIG":
            continue
        ev = event.get("Event", {})
        name = ev.get("UnicodeName", "").lower()
        if name not in out:
            continue
        data = ev.get("VariableData")
        if data is None:
            continue
        if isinstance(data, list):
            for entry in data:
                for key in entry.get("Keys", []):
                    so = key.get("SignatureOwner", "")
                    sd = key.get("SignatureData", "")
                    if so and sd:
                        out[name].append({
                            "SignatureOwner": so,
                            "SignatureData": f"0x{sd}",
                        })
    return out


def get_uki_digest(
    events: List[Dict[str, Any]],
) -> Dict[str, str]:
    """Get the UKI application digest from PCR 4.

    In a UKI boot there is exactly one non-firmware
    EV_EFI_BOOT_SERVICES_APPLICATION event in PCR 4.

    Firmware-resident applications are identified by
    ``FvVol(...)/FvFile(...)`` DevicePath strings.  These
    are decoded by ``tpm2_eventlog`` when libefivar is
    available (see ``LD_LIBRARY_PATH`` in the wrapper).
    """
    fw_pat = re.compile(
        r"FvVol\(\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\)"
        r"/FvFile\(\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\)"
    )
    apps = []
    for event in events:
        et = event.get("EventType", "")
        if et != "EV_EFI_BOOT_SERVICES_APPLICATION":
            continue
        if event.get("PCRIndex") != 4:
            continue
        ev = event.get("Event", {})
        dp = ev.get("DevicePath", "")
        if fw_pat.match(str(dp)):
            continue
        apps.append(event_to_sha256(event))

    if len(apps) != 1:
        print(
            "Warning: expected 1 non-firmware"
            " EV_EFI_BOOT_SERVICES_APPLICATION in PCR 4,"
            f" got {len(apps)}",
            file=sys.stderr,
        )
    return apps[0] if apps else {}


def create_refstate(
    events: List[Dict[str, Any]],
    userspace_events: Optional[
        List[Dict[str, Any]]
    ] = None,
) -> Dict[str, Any]:
    """Create a UKI measured boot reference state.

    Returns a dict with keys: scrtm_and_bios, pk, kek, db,
    dbx, uki_digest, and optionally userspace_digests
    for systemd runtime PCR extensions.
    """
    refstate: Dict[str, Any] = {
        "scrtm_and_bios": [{
            **get_scrtm(events),
            **get_platform_firmware(events),
        }],
        **get_keys(events),
        "uki_digest": get_uki_digest(events),
    }

    if userspace_events:
        refstate["userspace_digests"] = [
            {
                "pcr": ev["PCRIndex"],
                "digest": d["Digest"],
                "algorithm": d["AlgorithmId"],
            }
            for ev in userspace_events
            for d in ev.get("Digests", [])
        ]

    return refstate


# --- PCR replay ---


def parse_userspace_log(
    path: str = USERSPACE_TPM_LOG,
) -> List[Dict[str, Any]]:
    """Parse systemd's userspace TPM measurement log.

    systemd services (``systemd-pcrphase``,
    ``systemd-tpm2-setup``, etc.) extend PCRs from
    userspace via the TSS2 library.  These extensions are
    NOT in the UEFI event log but are recorded in
    RFC 7464 JSON-seq format at *path*.

    Returns a list of events in the same schema used by
    ``replay_pcrs``: each dict has ``PCRIndex`` and
    ``Digests`` (list of ``AlgorithmId`` / ``Digest``
    pairs).
    """
    log_path = Path(path)
    if not log_path.exists():
        return []

    events: List[Dict[str, Any]] = []
    try:
        text = log_path.read_text()
    except OSError as e:
        print(
            f"Warning: cannot read userspace TPM"
            f" log {path}: {e}",
            file=sys.stderr,
        )
        return []

    for line in text.splitlines():
        # RFC 7464: each record is preceded by 0x1E
        line = line.lstrip("\x1e").strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        pcr = record.get("pcr")
        if pcr is None:
            continue

        digests = []
        for d in record.get("digests", []):
            alg = d.get("hashAlg")
            digest_hex = d.get("digest")
            if alg and digest_hex:
                digests.append({
                    "AlgorithmId": alg,
                    "Digest": digest_hex,
                })

        if digests:
            events.append({
                "PCRIndex": pcr,
                "Digests": digests,
            })

    return events


def replay_pcrs(
    events: List[Dict[str, Any]],
    userspace_events: Optional[
        List[Dict[str, Any]]
    ] = None,
) -> Dict[int, str]:
    """Replay event log to compute expected PCR values.

    Extends SHA-256 digests per the TPM extend operation:
    ``new = SHA256(old || event_digest)``, starting from
    32 zero bytes.

    If *userspace_events* is provided (from
    ``parse_userspace_log``), those extends are applied
    after the UEFI event log events to account for
    runtime PCR extensions by systemd services.

    Returns a dict mapping PCR index to final hex digest.
    """
    pcrs: Dict[int, bytes] = {}

    all_events = list(events)
    if userspace_events:
        all_events.extend(userspace_events)

    for event in all_events:
        pcr_idx = event.get("PCRIndex")
        if pcr_idx is None:
            continue
        digest_hex = None
        for d in event.get("Digests", []):
            if d.get("AlgorithmId") == "sha256":
                digest_hex = d["Digest"]
                break
        if not digest_hex:
            continue
        if pcr_idx not in pcrs:
            pcrs[pcr_idx] = b"\x00" * 32
        pcrs[pcr_idx] = hashlib.sha256(
            pcrs[pcr_idx] + bytes.fromhex(digest_hex)
        ).digest()
    return {
        idx: pcrs[idx].hex()
        for idx in sorted(pcrs)
    }


def read_tpm_pcrs(
    sysfs: str = "/sys/class/tpm/tpm0/pcr-sha256",
) -> Dict[int, str]:
    """Read PCR values from TPM sysfs.

    Returns a dict mapping PCR index to hex digest for
    all PCRs present in the sysfs directory.
    """
    sysfs_path = Path(sysfs)
    pcrs: Dict[int, str] = {}
    if not sysfs_path.is_dir():
        return pcrs
    for entry in sorted(sysfs_path.iterdir()):
        if entry.name.isdigit():
            val = entry.read_text().strip().lower()
            if len(val) == 64:
                pcrs[int(entry.name)] = val
    return pcrs


# --- Refstate diffing ---


def _sig_key(
    sig: Dict[str, str],
) -> Tuple[str, str]:
    """Hashable key for a signature entry."""
    return (
        sig.get("SignatureOwner", ""),
        sig.get("SignatureData", ""),
    )


def _diff_sig_list(
    old: List[Dict[str, str]],
    new: List[Dict[str, str]],
) -> Optional[Dict[str, Any]]:
    """Diff two signature lists (pk, kek, db, dbx)."""
    old_set = {_sig_key(s) for s in old}
    new_set = {_sig_key(s) for s in new}
    if old_set == new_set:
        return None
    added = [
        {"SignatureOwner": k[0], "SignatureData": k[1]}
        for k in sorted(new_set - old_set)
    ]
    removed = [
        {"SignatureOwner": k[0], "SignatureData": k[1]}
        for k in sorted(old_set - new_set)
    ]
    return {"added": added, "removed": removed}


def _diff_digest(
    old: Dict[str, str],
    new: Dict[str, str],
) -> Optional[Dict[str, Any]]:
    """Diff two digest dicts (e.g. uki_digest, scrtm)."""
    if old == new:
        return None
    return {"old": old, "new": new}


def _diff_firmware(
    old: List[Dict[str, str]],
    new: List[Dict[str, str]],
) -> Optional[Dict[str, Any]]:
    """Diff firmware blob lists."""
    if old == new:
        return None
    old_digests = [
        d.get("sha256", "") for d in old
    ]
    new_digests = [
        d.get("sha256", "") for d in new
    ]
    return {
        "old_count": len(old),
        "new_count": len(new),
        "added": [
            d for d in new_digests
            if d not in old_digests
        ],
        "removed": [
            d for d in old_digests
            if d not in new_digests
        ],
    }


def diff_refstates(
    old: Dict[str, Any],
    new: Dict[str, Any],
) -> Dict[str, Any]:
    """Compare two refstate dicts field by field.

    Returns a dict mapping field names to their diff.
    Fields that are unchanged are mapped to None.
    """
    result: Dict[str, Any] = {}

    # uki_digest
    result["uki_digest"] = _diff_digest(
        old.get("uki_digest", {}),
        new.get("uki_digest", {}),
    )

    # scrtm
    old_bios = old.get("scrtm_and_bios", [{}])
    new_bios = new.get("scrtm_and_bios", [{}])
    old_scrtm = old_bios[0].get("scrtm", {}) if old_bios else {}
    new_scrtm = new_bios[0].get("scrtm", {}) if new_bios else {}
    result["scrtm"] = _diff_digest(old_scrtm, new_scrtm)

    # platform_firmware
    old_fw = old_bios[0].get("platform_firmware", []) if old_bios else []
    new_fw = new_bios[0].get("platform_firmware", []) if new_bios else []
    result["platform_firmware"] = _diff_firmware(
        old_fw, new_fw,
    )

    # Secure Boot keys
    for key in ("pk", "kek", "db", "dbx"):
        result[key] = _diff_sig_list(
            old.get(key, []),
            new.get(key, []),
        )

    return result
