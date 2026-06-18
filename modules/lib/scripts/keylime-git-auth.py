# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Auth subrequest backend for the attestation-gated git server.

nginx calls GET /verify?uuid=<agent-uuid> via auth_request.
Queries the keylime verifier and returns 200 (allow) or 403 (deny).
Binds to localhost only; nginx owns TLS and mTLS.

Environment variables:
    KEYLIME_VERIFIER_IP    (default: 127.0.0.1)
    KEYLIME_VERIFIER_PORT  (default: 8881)
    KEYLIME_TLS_DIR        (default: /var/lib/keylime/tls)
    KEYLIME_AUTH_PORT      (default: 8895)
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

VERIFIER_IP = os.environ.get("KEYLIME_VERIFIER_IP", "127.0.0.1")
VERIFIER_PORT = os.environ.get("KEYLIME_VERIFIER_PORT", "8881")
TLS_DIR = os.environ.get("KEYLIME_TLS_DIR", "/var/lib/keylime/tls")
AUTH_PORT = int(os.environ.get("KEYLIME_AUTH_PORT", "8895"))

# Allowlist of verifier operational states that indicate active attestation.
# Anything outside this set is denied, including states we do not recognise.
# Reference: keylime/common/states.py
_ALLOWED = frozenset({
    1,  # START
    2,  # SAVED
    3,  # GET_QUOTE
    4,  # GET_QUOTE_RETRY
    5,  # PROVIDE_V
    6,  # PROVIDE_V_RETRY
})

_ctx = None


def verifier_ctx():
    global _ctx
    if _ctx is None:
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.load_cert_chain(
            f"{TLS_DIR}/client-cert.pem",
            f"{TLS_DIR}/client-key.pem",
        )
        c.load_verify_locations(f"{TLS_DIR}/ca-cert.pem")
        c.check_hostname = False
        _ctx = c
    return _ctx


def is_attested(uuid):
    """Return True if uuid is in an allowed attestation state.

    HTTP errors (404 = not enrolled, etc.) return False.
    Network errors propagate so the caller can return 503.
    """
    url = f"https://{VERIFIER_IP}:{VERIFIER_PORT}/v2.5/agents/{uuid}"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url), context=verifier_ctx()
        ) as r:
            data = json.loads(r.read())
            state = data.get("results", {}).get("operational_state")
        return state in _ALLOWED
    except urllib.error.HTTPError:
        return False


class AuthHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        uuid = (qs.get("uuid") or [""])[0].strip()
        if not uuid:
            return self._reply(403, "no uuid")
        try:
            ok = is_attested(uuid)
        except Exception as exc:
            print(f"WARN verifier unreachable: {exc}", flush=True)
            return self._reply(503, "verifier unavailable")
        print(f"{'ALLOW' if ok else 'DENY'} {uuid}", flush=True)
        self._reply(200 if ok else 403, "ok" if ok else "denied")

    def _reply(self, code, msg):
        body = json.dumps({"status": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


for _p in ("ca-cert.pem", "client-cert.pem", "client-key.pem"):
    if not os.path.isfile(f"{TLS_DIR}/{_p}"):
        sys.exit(f"missing: {TLS_DIR}/{_p}")

print(f"keylime-git-auth :{AUTH_PORT}", flush=True)
HTTPServer(("127.0.0.1", AUTH_PORT), AuthHandler).serve_forever()
