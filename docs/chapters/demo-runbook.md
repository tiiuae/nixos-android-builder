# Demo Runbook: Attestation-Gated Git {#sec-demo-runbook .appendix}

Audience: demo operator (presenting to executives / customers)
Format: two machines side by side (~10 min)

See @sec-attestation-git-server for the technical reference.

## What We're Showing

A builder machine can only clone the Android signing-keys repository if its TPM attestation is passing. Revoking via `attestation-ctl` locks it out instantly — no reboot, no certificate rotation, no firewall change.

## Pre-Demo Prep

### 1. Populate demo repository on the server

```bash
git init --bare /var/lib/keylime-git/repos/android-signing-keys.git
# seed with realistic content (README + dummy keys)
git -C /var/lib/keylime-git/repos/android-signing-keys.git update-server-info
ln -s /etc/keylime-git/hooks/post-receive \
      /var/lib/keylime-git/repos/android-signing-keys.git/hooks/post-receive
```

### 2. Verify agent credentials

Client cert and key are written to `/run/keylime-git/` by `report-measured-boot-state`. The `keylime-git-clone` wrapper configures git automatically.

Preflight:

```bash
keylime-git-clone https://<server-ip>/android-signing-keys.git /tmp/preflight
ls /tmp/preflight/keys/
rm -rf /tmp/preflight
```

### 3. Terminal layout

**Server** — tmux, 3 panes:

- Top-left: ready for `attestation-ctl`
- Top-right: `journalctl -fu keylime-git-auth` (live ALLOW/DENY stream)
- Bottom: ready for `attestation-ctl remove <uuid>`

**Agent** — one clean pane at `~`.

### 4. Checklist (30 min before)

- [ ] Agent booted, attestation passing (`attestation-ctl status` shows PASS)
- [ ] Preflight clone succeeds
- [ ] `journalctl -fu keylime-git-auth` running
- [ ] Both screens visible

## Live Script

### Act 1 — The problem (1 min, verbal)

> "This builder produces Android images signed with production keys. Those keys live in a git repo. How do you make sure only a legitimate, unmodified builder gets them?"

### Act 2 — Attestation status (2 min)

```bash
attestation-ctl status
```

> "The server continuously verifies this machine's firmware, bootloader, and OS via the TPM. It passed 12 seconds ago."

### Act 3 — Attested clone (2 min)

On the agent:

```bash
keylime-git-clone https://<server-ip>/android-signing-keys.git
ls android-signing-keys/keys/
```

Server log shows: `ALLOW aabbccdd-… — agent is attested`

### Act 4 — Revocation (3 min)

On the server:

```bash
attestation-ctl remove <uuid>
```

On the agent:

```bash
keylime-git-clone https://<server-ip>/android-signing-keys.git /tmp/second
# fatal: 403
```

Server log shows: `DENY aabbccdd-… — agent not enrolled`

> "Same machine. Same certificate. Only the attestation status changed."

### Act 5 — Q&A (2 min)

| Question | Answer |
|----------|--------|
| Stolen certificate? | Server checks live attestation status on every request. |
| Faked TPM / VM? | EK certificate verified against manufacturer CA. |
| How often re-checked? | Every git request; verifier re-attests every 2 seconds. |
| Can the builder push? | No — read-only from agent side. |

## Recovery

Re-enroll after demo. The agent must re-register (reboot it or restart `keylime-agent`):

```bash
# On the agent — re-register with registrar and re-POST refstate
systemctl reboot

# On the server — wait for auto-enrollment (~30 seconds after agent boots)
attestation-ctl status
```
