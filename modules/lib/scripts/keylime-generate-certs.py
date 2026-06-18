#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Generate Keylime TLS PKI if not already present.

Expected environment variables (set by the systemd service):
  KEYLIME_TLS_DIR       — directory for cert files (e.g. /var/lib/keylime/tls)
  KEYLIME_CERT_DAYS     — certificate validity in days
  KEYLIME_EXTRA_SANS    — JSON list of additional SANs (e.g. '["IP:10.0.0.1"]')

Expected on PATH: openssl, ip, chown
"""

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile


def env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        print(f"error: {name} not set", file=sys.stderr)
        sys.exit(1)
    return value


def run(*args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, **kwargs)  # type: ignore[arg-type]


def get_sans(extra: list[str]) -> str:
    hostname = socket.getfqdn()
    sans = [f"DNS:{hostname}", "DNS:localhost", "IP:127.0.0.1"]

    # Add all non-loopback IPs so agents can connect by any address.
    result = subprocess.run(
        ["ip", "-o", "addr", "show", "scope", "global"],
        capture_output=True,
        text=True,
        check=True,
    )
    for line in result.stdout.splitlines():
        addr = line.split()[3].split("/")[0]
        sans.append(f"IP:{addr}")

    sans.extend(extra)
    return ",".join(sans)


def main() -> None:
    tls_dir = env("KEYLIME_TLS_DIR")
    cert_days = env("KEYLIME_CERT_DAYS")
    extra_sans: list[str] = json.loads(env("KEYLIME_EXTRA_SANS"))

    ca_cert = f"{tls_dir}/ca-cert.pem"
    ca_key = f"{tls_dir}/ca-key.pem"
    server_cert = f"{tls_dir}/server-cert.pem"
    server_key = f"{tls_dir}/server-key.pem"
    client_cert = f"{tls_dir}/client-cert.pem"
    client_key = f"{tls_dir}/client-key.pem"

    if os.path.exists(ca_cert):
        print("keylime-tls: certificates already exist, skipping generation")
        return

    print(f"keylime-tls: generating TLS PKI in {tls_dir} ...")
    os.makedirs(tls_dir, exist_ok=True)
    sans = get_sans(extra_sans)
    print(f"keylime-tls: SANs: {sans}")

    # CA
    run(
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", ca_key, "-out", ca_cert,
        "-days", cert_days, "-subj", "/CN=Keylime CA",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
    )

    # Server cert
    server_csr = f"{tls_dir}/server.csr"
    run(
        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", server_key, "-out", server_csr,
        "-subj", "/CN=keylime-server",
    )
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".cnf", delete=False,
    ) as f:
        f.write(f"subjectAltName={sans}\n")
        extfile = f.name
    try:
        run(
            "openssl", "x509", "-req",
            "-in", server_csr, "-CA", ca_cert, "-CAkey", ca_key,
            "-CAcreateserial", "-out", server_cert,
            "-days", cert_days, "-sha256", "-extfile", extfile,
        )
    finally:
        os.unlink(extfile)

    # Client cert (verifier -> registrar mTLS)
    client_csr = f"{tls_dir}/client.csr"
    run(
        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", client_key, "-out", client_csr,
        "-subj", "/CN=keylime-client",
    )
    run(
        "openssl", "x509", "-req",
        "-in", client_csr, "-CA", ca_cert, "-CAkey", ca_key,
        "-CAcreateserial", "-out", client_cert,
        "-days", cert_days, "-sha256",
    )

    # Cleanup CSRs and serial files
    for pattern in ("*.csr", "*.srl"):
        for p in pathlib.Path(tls_dir).glob(pattern):
            p.unlink()

    # Permissions
    run("chown", "-R", "keylime:keylime", tls_dir)
    os.chmod(tls_dir, 0o750)
    for p in pathlib.Path(tls_dir).glob("*.pem"):
        os.chmod(p, 0o640)

    print("keylime-tls: PKI generation complete")


main()
