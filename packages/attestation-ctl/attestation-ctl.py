# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Client-side tool for managing remote attestation agents.

Reads the attestation server address and CA cert from
``attestation-server.json`` (same config the agent uses)
and client mTLS certs from ``keys/keylime/``.

Usage::

    attestation-ctl status
    attestation-ctl inspect <uuid>
    attestation-ctl remove <uuid|all>
"""

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path


def load_config(args):
    """Load server address and TLS context."""
    if args.server:
        server = args.server
    else:
        cfg_path = Path.cwd() / "attestation-server.json"
        if not cfg_path.exists():
            print(
                "Error: attestation-server.json not"
                " found. Use --server or run from the"
                " repo root.",
                file=sys.stderr,
            )
            sys.exit(1)
        with open(cfg_path) as f:
            cfg = json.load(f)
        server = cfg["ip"]

    # TLS context
    cert_dir = Path(args.cert_dir)
    cert = cert_dir / "client-cert.pem"
    key = cert_dir / "client-key.pem"
    ca = cert_dir / "ca-cert.pem"

    for p in (cert, key, ca):
        if not p.exists():
            print(
                f"Error: {p} not found.",
                file=sys.stderr,
            )
            sys.exit(1)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(str(cert), str(key))
    ctx.load_verify_locations(str(ca))
    ctx.check_hostname = False

    return server, ctx


def api_get(url, ctx):
    """GET a keylime API endpoint, return parsed JSON."""
    try:
        with urllib.request.urlopen(url, context=ctx) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError:
        return None
    except urllib.error.URLError as e:
        print(f"Error: {e.reason}", file=sys.stderr)
        sys.exit(1)


def api_delete(url, ctx):
    """DELETE a keylime API endpoint."""
    req = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(req, context=ctx) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def get_registrar_uuids(server, ctx):
    """List agent UUIDs from the registrar."""
    data = api_get(
        f"https://{server}:8891/v2.5/agents/", ctx,
    )
    if data is None:
        return []
    return data.get("results", {}).get("uuids", [])


def get_verifier_agents(server, ctx):
    """List agent UUIDs from the verifier."""
    data = api_get(
        f"https://{server}:8881/v2.5/agents/", ctx,
    )
    if data is None:
        return []
    raw = data.get("results", {}).get("uuids", [])
    # The verifier API returns [["uuid"], …] not ["uuid", …]
    return [
        e[0] if isinstance(e, list) else e
        for e in raw
    ]


def get_verifier_agent(server, ctx, uuid):
    """Get detailed agent info from the verifier."""
    return api_get(
        f"https://{server}:8881/v2.5/agents/{uuid}",
        ctx,
    )


def short_uuid(uuid):
    return uuid[:12] + "…"


def _format_last_success(results):
    """Format the last successful attestation as a
    relative time string, or return None."""
    ts = results.get("last_successful_attestation")
    if not ts:
        return None
    import time
    secs = int(time.time() - ts)
    if secs < 0:
        return "just now"
    if secs < 60:
        return f"{secs}s ago"
    if secs < 3600:
        return f"{secs // 60}m ago"
    if secs < 86400:
        return f"{secs // 3600}h ago"
    return f"{secs // 86400}d ago"


def cmd_status(args):
    server, ctx = load_config(args)

    reg_uuids = set(get_registrar_uuids(server, ctx))
    ver_uuids = set(get_verifier_agents(server, ctx))
    all_uuids = sorted(reg_uuids | ver_uuids)

    if not all_uuids:
        print("No agents found.")
        return

    print(
        f"{'UUID':<66} {'REGISTRAR':>10}"
        f" {'VERIFIER':>10} {'STATUS':>10}"
        f"  {'LAST OK':>10}  {'#':>4}"
    )
    print("─" * 120)

    for uuid in all_uuids:
        in_reg = "✓" if uuid in reg_uuids else "—"
        in_ver = "✓" if uuid in ver_uuids else "—"
        status = "—"
        last_ok = "—"
        count = "—"

        if uuid in ver_uuids:
            info = get_verifier_agent(server, ctx, uuid)
            if info:
                r = info.get("results", {})
                last_ok = (
                    _format_last_success(r) or "never"
                )
                c = r.get("attestation_count")
                count = str(c) if c is not None else "—"
                status = r.get(
                    "attestation_status",
                    r.get("operational_state", "—"),
                )

        print(
            f"{uuid:<66} {in_reg:>10}"
            f" {in_ver:>10} {status:>10}"
            f"  {last_ok:>10}  {count:>4}"
        )

    print()
    print(
        f"{len(reg_uuids)} registered,"
        f" {len(ver_uuids)} enrolled"
    )


def cmd_inspect(args):
    server, ctx = load_config(args)
    uuid = args.uuid

    print(f"Agent: {uuid}")
    print()

    # Registrar info
    reg = api_get(
        f"https://{server}:8891/v2.5/agents/{uuid}",
        ctx,
    )
    if reg:
        print("Registrar: registered ✓")
    else:
        print("Registrar: not found")

    print()

    # Verifier info
    ver = get_verifier_agent(server, ctx, uuid)
    if not ver:
        print("Verifier: not enrolled")
        return

    r = ver.get("results", {})
    print("Verifier: enrolled ✓")
    for key in (
        "operational_state",
        "attestation_status",
        "attestation_count",
        "last_successful_attestation",
    ):
        val = r.get(key)
        if val is not None:
            print(f"  {key}: {val}")

    # Refstate summary
    mb = r.get("mb_refstate")
    if mb:
        if isinstance(mb, str):
            try:
                mb = json.loads(mb)
            except json.JSONDecodeError:
                pass
        if isinstance(mb, dict):
            print()
            print("Measured boot refstate:")
            uki = mb.get("uki_digest", {})
            if uki:
                d = uki.get("sha256", "?")
                print(f"  uki_digest: {d[:20]}…")
            keys_info = []
            for k in ("pk", "kek", "db", "dbx"):
                n = len(mb.get(k, []))
                if n:
                    keys_info.append(f"{k}={n}")
            if keys_info:
                print(
                    f"  secure boot keys:"
                    f" {', '.join(keys_info)}"
                )
            bios = mb.get("scrtm_and_bios", [])
            if bios:
                fw = bios[0].get(
                    "platform_firmware", [],
                )
                print(
                    f"  firmware blobs: {len(fw)}"
                )


def cmd_remove(args):
    server, ctx = load_config(args)

    if args.uuid == "all":
        reg = set(get_registrar_uuids(server, ctx))
        ver = set(get_verifier_agents(server, ctx))
        uuids = sorted(reg | ver)
        if not uuids:
            print("No agents to remove.")
            return
        print(f"Removing {len(uuids)} agent(s)…")
    else:
        uuids = [args.uuid]

    for uuid in uuids:
        print(f"  {short_uuid(uuid)}")

        code = api_delete(
            f"https://{server}:8881/v2.5/agents/{uuid}",
            ctx,
        )
        if code and 200 <= code < 300:
            print("    verifier: removed")
        elif code == 404:
            print("    verifier: not enrolled")
        else:
            print(f"    verifier: HTTP {code}")

        code = api_delete(
            f"https://{server}:8891/v2.5/agents/{uuid}",
            ctx,
        )
        if code and 200 <= code < 300:
            print("    registrar: removed")
        elif code == 404:
            print("    registrar: not found")
        else:
            print(f"    registrar: HTTP {code}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage remote attestation agents",
        prog="attestation-ctl",
    )
    parser.add_argument(
        "--server",
        help=(
            "Attestation server IP"
            " (default: from attestation-server.json)"
        ),
    )
    parser.add_argument(
        "--cert-dir",
        default="keys/keylime",
        help=(
            "Directory with client-cert.pem,"
            " client-key.pem, ca-cert.pem"
            " (default: keys/keylime)"
        ),
    )

    sub = parser.add_subparsers(dest="command")
    sub.required = True

    sub.add_parser(
        "status",
        help="List agents and their attestation state",
    )

    p_inspect = sub.add_parser(
        "inspect",
        help="Show detailed info for an agent",
    )
    p_inspect.add_argument("uuid", help="Agent UUID")

    p_remove = sub.add_parser(
        "remove",
        help=(
            "Remove agent from verifier and registrar"
            " (use 'all' to remove all)"
        ),
    )
    p_remove.add_argument(
        "uuid",
        help="Agent UUID or 'all'",
    )

    args = parser.parse_args()

    cmds = {
        "status": cmd_status,
        "inspect": cmd_inspect,
        "remove": cmd_remove,
    }
    cmds[args.command](args)


if __name__ == "__main__":
    main()
