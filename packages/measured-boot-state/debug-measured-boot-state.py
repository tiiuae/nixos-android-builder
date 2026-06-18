# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Debug measured boot state mismatches.

Diagnoses why attestation fails by replaying the UEFI event log,
comparing PCR values against the TPM, and diffing the current
reference state against a saved or enrolled one.

Usage:

    # Save current refstate (for comparison after reboot)
    debug-measured-boot-state save
    debug-measured-boot-state save -o /tmp/refstate.json

    # Diagnose live system (auto-detects saved refstate)
    debug-measured-boot-state

    # Diagnose against a specific enrolled refstate
    debug-measured-boot-state diagnose -r enrolled.json

    # Diagnose with explicit event log (offline)
    debug-measured-boot-state diagnose -e log.bin -r enrolled.json

    # Diff two refstate files (no live system needed)
    debug-measured-boot-state diagnose old.json new.json
"""

import argparse
import json
import sys
from pathlib import Path

from measured_boot_state import (
    UEFI_EVENTLOG,
    TPM_SYSFS,
    USERSPACE_TPM_LOG,
    create_refstate,
    diff_refstates,
    parse_eventlog,
    parse_userspace_log,
    read_tpm_pcrs,
    replay_pcrs,
)

# PCRs relevant to the UKI measured boot policy.
POLICY_PCRS = [0, 1, 2, 3, 4, 5, 7, 9, 11]

# Well-known path for saved refstates on the persistent
# keylime partition.  Used by 'save' (default output) and
# 'diagnose' (auto-detect).
DEFAULT_REFSTATE = (
    "/var/lib/keylime/saved-refstate.json"
)


def print_pcr_comparison(
    replayed: dict, tpm: dict,
) -> bool:
    """Print PCR replay vs TPM comparison.

    Returns True if all relevant PCRs match.
    """
    print("PCR replay vs TPM:")
    all_match = True
    for pcr in POLICY_PCRS:
        r = replayed.get(pcr)
        t = tpm.get(pcr)
        if r is None:
            print(f"  PCR {pcr:>2}: - (not in event log)")
            continue
        if t is None:
            print(f"  PCR {pcr:>2}: - (not in TPM sysfs)")
            continue
        if r == t:
            print(f"  PCR {pcr:>2}: \u2713 match")
        else:
            print(f"  PCR {pcr:>2}: \u2717 MISMATCH")
            print(f"    replayed: {r}")
            print(f"    tpm:      {t}")
            all_match = False
    return all_match


def print_refstate_diff(diff: dict) -> bool:
    """Print a structured refstate diff.

    Returns True if refstates are identical.
    """
    print("Refstate diff:")
    all_same = True
    for field, change in diff.items():
        if change is None:
            print(f"  {field}: unchanged")
            continue
        all_same = False
        if "old" in change and "new" in change:
            # Digest change
            old_v = change["old"].get("sha256", str(change["old"]))
            new_v = change["new"].get("sha256", str(change["new"]))
            print(f"  {field}: CHANGED")
            print(f"    old: {old_v}")
            print(f"    new: {new_v}")
        elif "added" in change and "removed" in change:
            if "old_count" in change:
                # Firmware blobs
                print(
                    f"  {field}: CHANGED"
                    f" ({change['old_count']}"
                    f" -> {change['new_count']})"
                )
                for d in change["removed"]:
                    print(f"    - {d}")
                for d in change["added"]:
                    print(f"    + {d}")
            else:
                # Signature list
                added = change["added"]
                removed = change["removed"]
                parts = []
                if added:
                    parts.append(
                        f"+{len(added)} added"
                    )
                if removed:
                    parts.append(
                        f"-{len(removed)} removed"
                    )
                print(
                    f"  {field}: CHANGED"
                    f" ({', '.join(parts)})"
                )
                for s in removed:
                    owner = s["SignatureOwner"]
                    data = s["SignatureData"]
                    print(
                        f"    - Owner={owner}"
                        f" Data={data}"
                    )
                for s in added:
                    owner = s["SignatureOwner"]
                    data = s["SignatureData"]
                    print(
                        f"    + Owner={owner}"
                        f" Data={data}"
                    )
    return all_same


def print_event_summary(
    events: list, refstate: dict,
) -> None:
    """Print per-event check against refstate.

    Checks pinned fields (SCRTM, firmware, UKI, Secure Boot
    keys) against the refstate and reports pass/fail.
    """
    print("\nPolicy evaluation (pinned fields):")

    bios = refstate.get("scrtm_and_bios", [{}])
    ref_scrtm = (
        bios[0].get("scrtm", {}) if bios else {}
    )
    ref_fw = (
        bios[0].get("platform_firmware", [])
        if bios else []
    )
    ref_uki = refstate.get("uki_digest", {})
    ref_keys = {
        k: refstate.get(k, [])
        for k in ("pk", "kek", "db", "dbx")
    }

    import re
    fw_pat = re.compile(
        r"FvVol\(\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\)"
        r"/FvFile\(\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\)"
    )
    fw_idx = 0

    for event in events:
        et = event.get("EventType", "")
        pcr = event.get("PCRIndex", "?")
        digests = event.get("Digests", [])
        sha = ""
        for d in digests:
            if d.get("AlgorithmId") == "sha256":
                sha = f"0x{d['Digest']}"
                break

        if et == "EV_S_CRTM_VERSION":
            expected = ref_scrtm.get("sha256", "")
            ok = sha == expected
            mark = "\u2713" if ok else "\u2717 FAILED"
            print(
                f"  PCR {pcr:>2}"
                f" {et}: {mark}"
            )
            if not ok:
                print(f"    expected: {expected}")
                print(f"    got:      {sha}")

        elif et in (
            "EV_EFI_PLATFORM_FIRMWARE_BLOB",
            "EV_EFI_PLATFORM_FIRMWARE_BLOB2",
        ):
            expected = ""
            if fw_idx < len(ref_fw):
                expected = ref_fw[fw_idx].get(
                    "sha256", ""
                )
            ok = sha == expected
            mark = "\u2713" if ok else "\u2717 FAILED"
            print(
                f"  PCR {pcr:>2}"
                f" {et}"
                f" #{fw_idx}: {mark}"
            )
            if not ok:
                print(f"    expected: {expected}")
                print(f"    got:      {sha}")
            fw_idx += 1

        elif et == "EV_EFI_BOOT_SERVICES_APPLICATION":
            ev = event.get("Event", {})
            dp = ev.get("DevicePath", "")
            if fw_pat.match(str(dp)):
                continue
            expected = ref_uki.get("sha256", "")
            ok = sha == expected
            mark = "\u2713" if ok else "\u2717 FAILED"
            print(
                f"  PCR {pcr:>2}"
                f" {et}: {mark}"
            )
            if not ok:
                print(f"    expected: {expected}")
                print(f"    got:      {sha}")
                print(
                    "    \u2192 UKI image changed;"
                    " re-enroll with new refstate"
                )

        elif et == "EV_EFI_VARIABLE_DRIVER_CONFIG":
            ev = event.get("Event", {})
            name = ev.get("UnicodeName", "")
            name_lower = name.lower()
            if name_lower in ref_keys:
                # Just report presence — deep key
                # comparison is done in refstate diff
                print(
                    f"  PCR {pcr:>2}"
                    f" {et}"
                    f" {name}: \u2713 (see refstate diff"
                    f" for key details)"
                )


def cmd_save(args: argparse.Namespace) -> int:
    """Save the current measured boot refstate."""
    eventlog_path = args.eventlog
    if not Path(eventlog_path).exists():
        print(
            f"Error: event log not found: {eventlog_path}",
            file=sys.stderr,
        )
        return 1

    log_data = parse_eventlog(eventlog_path)
    if not log_data:
        return 1
    events = log_data.get("events", [])
    if not events:
        print("No events in event log", file=sys.stderr)
        return 1

    userspace_events = parse_userspace_log(
        args.userspace_log,
    )

    refstate = create_refstate(events, userspace_events)

    output = args.output
    with open(output, "w") as f:
        json.dump(refstate, f, indent=2)
    print(f"Saved refstate to {output}", file=sys.stderr)
    return 0


def cmd_diagnose(args: argparse.Namespace) -> int:
    """Diagnose event log against TPM and optionally a refstate.

    When two positional refstate files are given, performs a
    pure offline diff (no event log or TPM needed).
    """
    # Pure diff mode: two positional refstate files
    if args.refstates and len(args.refstates) == 2:
        old_path, new_path = args.refstates
        for path in (old_path, new_path):
            if not Path(path).exists():
                print(
                    f"Error: file not found: {path}",
                    file=sys.stderr,
                )
                return 1
        with open(old_path) as f:
            old = json.load(f)
        with open(new_path) as f:
            new = json.load(f)
        diff = diff_refstates(old, new)
        same = print_refstate_diff(diff)
        return 0 if same else 2

    if args.refstates and len(args.refstates) != 0:
        print(
            "Error: provide exactly two refstate files"
            " for diff mode, or use --refstate for"
            " single-file comparison.",
            file=sys.stderr,
        )
        return 1

    # Live diagnose mode
    eventlog_path = args.eventlog
    if not Path(eventlog_path).exists():
        print(
            f"Error: event log not found: {eventlog_path}",
            file=sys.stderr,
        )
        return 1

    log_data = parse_eventlog(eventlog_path)
    if not log_data:
        return 1
    events = log_data.get("events", [])
    if not events:
        print("No events in event log", file=sys.stderr)
        return 1

    exit_code = 0

    # Parse systemd's userspace TPM measurement log
    userspace_events = parse_userspace_log(
        args.userspace_log,
    )
    if userspace_events:
        print(
            f"Loaded {len(userspace_events)} userspace"
            f" TPM event(s) from {args.userspace_log}",
        )

    # PCR replay vs TPM
    replayed = replay_pcrs(events, userspace_events)
    tpm = read_tpm_pcrs(args.tpm_sysfs)
    if tpm:
        pcr_ok = print_pcr_comparison(replayed, tpm)
        if not pcr_ok:
            exit_code = 2
    else:
        print(
            f"TPM sysfs not available at {args.tpm_sysfs};"
            " showing replayed PCRs only:"
        )
        for pcr in POLICY_PCRS:
            val = replayed.get(pcr, "(none)")
            print(f"  PCR {pcr:>2}: {val}")
    print()

    # Resolve refstate: explicit flag, auto-detect, or none
    refstate_path = args.refstate
    if not refstate_path and Path(DEFAULT_REFSTATE).exists():
        refstate_path = DEFAULT_REFSTATE
        print(
            f"Auto-detected saved refstate:"
            f" {refstate_path}"
        )

    if refstate_path:
        if not Path(refstate_path).exists():
            print(
                f"Error: refstate not found:"
                f" {refstate_path}",
                file=sys.stderr,
            )
            return 1
        with open(refstate_path) as f:
            enrolled = json.load(f)
        current = create_refstate(events)
        diff = diff_refstates(enrolled, current)
        ref_ok = print_refstate_diff(diff)
        if not ref_ok:
            exit_code = max(exit_code, 2)

        print_event_summary(events, enrolled)
    else:
        print(
            "No refstate to compare against."
        )
        print(
            "Tip: run 'debug-measured-boot-state save'"
            " before rebooting, then diagnose will"
            " auto-detect it."
        )

    return exit_code


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Debug measured boot policy mismatches"
        ),
    )
    sub = parser.add_subparsers(dest="command")

    # save subcommand
    save = sub.add_parser(
        "save",
        help=(
            "Save current refstate for later comparison"
        ),
    )
    save.add_argument(
        "-o", "--output",
        default=DEFAULT_REFSTATE,
        help=(
            "Output file"
            f" (default: {DEFAULT_REFSTATE})"
        ),
    )
    save.add_argument(
        "-e", "--eventlog",
        default=UEFI_EVENTLOG,
        help=(
            "Binary UEFI event log"
            f" (default: {UEFI_EVENTLOG})"
        ),
    )
    save.add_argument(
        "--userspace-log",
        default=USERSPACE_TPM_LOG,
        help=(
            "systemd userspace TPM measurement log"
            f" (default: {USERSPACE_TPM_LOG})"
        ),
    )

    # diagnose subcommand (also the default)
    diag = sub.add_parser(
        "diagnose",
        help=(
            "Diagnose event log against TPM and"
            " refstate, or diff two refstate files"
        ),
    )
    diag.add_argument(
        "-e", "--eventlog",
        default=UEFI_EVENTLOG,
        help=(
            "Binary UEFI event log"
            f" (default: {UEFI_EVENTLOG})"
        ),
    )
    diag.add_argument(
        "-r", "--refstate",
        help=(
            "Enrolled refstate JSON to compare against"
            f" (auto-detected from {DEFAULT_REFSTATE}"
            " if not given)"
        ),
    )
    diag.add_argument(
        "--tpm-sysfs",
        default=TPM_SYSFS,
        help=f"TPM PCR sysfs path (default: {TPM_SYSFS})",
    )
    diag.add_argument(
        "--userspace-log",
        default=USERSPACE_TPM_LOG,
        help=(
            "systemd userspace TPM measurement log"
            f" (default: {USERSPACE_TPM_LOG})"
        ),
    )
    diag.add_argument(
        "refstates",
        nargs="*",
        metavar="REFSTATE",
        help=(
            "Two refstate JSON files to diff"
            " (offline mode, no event log needed)"
        ),
    )

    args = parser.parse_args()

    if args.command == "save":
        sys.exit(cmd_save(args))
    elif args.command == "diagnose":
        sys.exit(cmd_diagnose(args))
    else:
        # Default to diagnose if no subcommand given
        args.eventlog = UEFI_EVENTLOG
        args.refstate = None
        args.refstates = []
        args.tpm_sysfs = TPM_SYSFS
        args.userspace_log = USERSPACE_TPM_LOG
        sys.exit(cmd_diagnose(args))


if __name__ == "__main__":
    main()
