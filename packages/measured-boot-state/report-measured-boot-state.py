# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Report measured boot state to the auto-enrollment server.

Generates a measured boot reference state from the UEFI
event log using the ``measured_boot_state`` library and POSTs it to
the auto-enrollment HTTPS endpoint on the attestation server.

The agent UUID is read from the keylime agent's
``agent_data.json`` file, which stores the EK hash (== the
UUID in ``hash_ek`` mode) as a byte array of the hex-encoded
SHA-256 digest.

Environment variables:
    KEYLIME_ENROLL_PORT     Port for enrollment endpoint
    KEYLIME_AGENT_UUID      Override UUID
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error
import ssl
from pathlib import Path

from measured_boot_state import (
    UEFI_EVENTLOG,
    USERSPACE_TPM_LOG,
    create_refstate,
    parse_eventlog,
    parse_userspace_log,
)

ATTESTATION_SERVER = Path("/boot/attestation-server.json")
AGENT_DATA = Path("/var/lib/keylime/agent_data.json")
GIT_CERT_DIR = Path("/run/keylime-git")


def generate_measured_boot_state(
    eventlog: str,
    userspace_log: str,
) -> dict:
    """Generate measured boot reference state."""
    if not Path(eventlog).exists():
        print(
            "Error: UEFI event log not found at"
            f" {eventlog}",
            file=sys.stderr,
        )
        sys.exit(1)

    log_data = parse_eventlog(eventlog)
    if not log_data:
        print(
            "Error: failed to parse UEFI event log",
            file=sys.stderr,
        )
        sys.exit(1)

    events = log_data.get("events", [])
    if not events:
        print(
            "Error: no events in UEFI event log",
            file=sys.stderr,
        )
        sys.exit(1)

    userspace_events = parse_userspace_log(
        userspace_log,
    )
    if userspace_events:
        print(
            f"Loaded {len(userspace_events)} userspace"
            f" TPM event(s) from {userspace_log}",
            file=sys.stderr,
        )

    return create_refstate(events, userspace_events)


def get_agent_uuid(timeout: int = 60) -> str:
    """Read the agent UUID from agent_data.json."""
    env_uuid = os.environ.get("KEYLIME_AGENT_UUID")
    if env_uuid:
        return env_uuid

    deadline = time.monotonic() + timeout
    while True:
        if AGENT_DATA.exists():
            try:
                with open(AGENT_DATA) as f:
                    data = json.load(f)
                ek_hash_bytes = data.get("ek_hash")
                if ek_hash_bytes and isinstance(
                    ek_hash_bytes, list,
                ):
                    return bytes(
                        ek_hash_bytes,
                    ).decode("ascii")
            except (
                json.JSONDecodeError, ValueError, KeyError,
            ):
                pass

        if time.monotonic() >= deadline:
            print(
                "Error: timed out waiting for"
                f" ek_hash in {AGENT_DATA}",
                file=sys.stderr,
            )
            sys.exit(1)

        time.sleep(2)


def get_enroll_config() -> tuple[str, str]:
    """Determine enrollment server URL and CA cert."""
    port = os.environ.get("KEYLIME_ENROLL_PORT", "8893")

    if not ATTESTATION_SERVER.exists():
        print(
            f"Error: {ATTESTATION_SERVER} not found.",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(ATTESTATION_SERVER) as f:
        data = json.load(f)

    ip = data.get("ip")
    if not ip:
        print(
            "Error: attestation-server.json"
            " missing 'ip'",
            file=sys.stderr,
        )
        sys.exit(1)

    ca_cert = data.get("ca_cert")
    if not ca_cert:
        print(
            "Error: attestation-server.json"
            " missing 'ca_cert'",
            file=sys.stderr,
        )
        sys.exit(1)

    url = f"https://{ip}:{port}"
    return url.rstrip("/"), ca_cert


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Report measured boot reference state"
            " to the auto-enrollment server"
        ),
    )
    parser.add_argument(
        "-e", "--eventlog",
        default=UEFI_EVENTLOG,
        help=(
            "Binary UEFI event log"
            f" (default: {UEFI_EVENTLOG})"
        ),
    )
    parser.add_argument(
        "--userspace-log",
        default=USERSPACE_TPM_LOG,
        help=(
            "systemd userspace TPM measurement log"
            f" (default: {USERSPACE_TPM_LOG})"
        ),
    )
    args = parser.parse_args()

    measured_boot_state = generate_measured_boot_state(
        args.eventlog, args.userspace_log,
    )
    uuid = get_agent_uuid()
    url, ca_cert = get_enroll_config()

    # Write CA cert to the git credential dir early so it is available
    # to unprivileged users even if attestation or cert fetch fails.
    GIT_CERT_DIR.mkdir(parents=True, exist_ok=True)
    ca_path = GIT_CERT_DIR / "ca-cert.pem"
    ca_path.write_text(
        ca_cert if ca_cert.endswith("\n") else ca_cert + "\n",
    )
    ca_path.chmod(0o644)

    print(f"Agent UUID: {uuid}", file=sys.stderr)
    print(
        "MB refstate keys:"
        f" {', '.join(sorted(measured_boot_state.keys()))}",
        file=sys.stderr,
    )
    print(f"Enrollment server: {url}", file=sys.stderr)

    endpoint = f"{url}/v1/report_measured_boot_state"
    payload = json.dumps({
        "uuid": uuid,
        "measured_boot_state": measured_boot_state,
    }).encode()

    ctx = ssl.create_default_context(cadata=ca_cert)

    req = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(
            req, context=ctx,
        ) as resp:
            body = json.loads(resp.read())
    except urllib.error.URLError as e:
        print(
            f"Error: POST to {endpoint} failed: {e}",
            file=sys.stderr,
        )
        sys.exit(1)
    except json.JSONDecodeError:
        print(
            "Error: unexpected response from"
            f" {endpoint}",
            file=sys.stderr,
        )
        sys.exit(1)

    if body.get("status") != "accepted":
        print(
            "Error: server response:"
            f" {json.dumps(body)}",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        "Measured boot report accepted.",
        file=sys.stderr,
    )

    # Fetch git client cert from the enrollment server.
    # The server only issues certs for attested agents, so we
    # retry until attestation succeeds (enrollment is async).
    cert_endpoint = f"{url}/v1/cert/{uuid}"
    for attempt in range(60):
        try:
            cert_req = urllib.request.Request(
                cert_endpoint,
            )
            with urllib.request.urlopen(
                cert_req, context=ctx,
            ) as cert_resp:
                cert_body = json.loads(
                    cert_resp.read(),
                )
            break
        except urllib.error.HTTPError as e:
            if e.code == 403:
                # Not attested yet — wait and retry
                if attempt == 0:
                    print(
                        "Waiting for attestation"
                        " before fetching git cert...",
                        file=sys.stderr,
                    )
                time.sleep(5)
                continue
            print(
                f"Error fetching cert: {e}",
                file=sys.stderr,
            )
            sys.exit(1)
        except urllib.error.URLError as e:
            print(
                f"Error fetching cert: {e}",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        print(
            "Error: timed out waiting for"
            " attestation to fetch git cert",
            file=sys.stderr,
        )
        sys.exit(1)

    client_cert = cert_body.get("client_cert")
    client_key = cert_body.get("client_key")
    if client_cert and client_key:
        cert_path = GIT_CERT_DIR / "client-cert.pem"
        key_path = GIT_CERT_DIR / "client-key.pem"
        cert_path.write_text(client_cert)
        key_path.write_text(client_key)
        cert_path.chmod(0o644)
        key_path.chmod(0o644)
        print(
            f"Git client cert saved to {cert_path}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
