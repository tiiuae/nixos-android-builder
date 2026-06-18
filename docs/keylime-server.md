<!--
SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
SPDX-License-Identifier: CC-BY-SA-4.0
-->

---
title: Keylime Server Setup
---

# Overview

The `system-manager/` directory contains a [numtide/system-manager](https://github.com/numtide/system-manager) configuration that turns a standard Ubuntu (or other non-NixOS) machine into a **Keylime attestation server**. This server is the counterpart to the NixOS Android Builder agents: it runs the Keylime registrar, verifier, and an auto-enrollment daemon so that builder machines can be remotely attested via their TPM2 chips.

System-manager is a tool that applies NixOS-style module configurations (services, users, files, etc.) to non-NixOS Linux distributions. It manages a subset of the system declaratively through Nix, without replacing the host OS.

## What It Runs

The configuration deploys four core systemd services plus an optional attestation-gated git server:

- **keylime-registrar** — Accepts TPM identity registrations from agents. Agents contact the registrar when they first boot and present their Endorsement Key (EK) and Attestation Key (AK).
- **keylime-verifier** — Continuously attests enrolled agents by requesting TPM quotes and verifying them against a measured boot reference state. Uses the custom `uki` measured boot policy.
- **keylime-auto-enroll** — A custom daemon that bridges registration and verification. It exposes an HTTPS endpoint for agents to submit their measured boot state, polls the registrar for new agents, and automatically enrolls them with the verifier once both conditions are met.
- **keylime-tls** — A oneshot service that auto-generates a self-signed CA and mTLS PKI (CA, server, and client certificates) in `/var/lib/keylime/tls/` on first activation. Existing certificates are never overwritten.
- **keylime-git-nginx** / **keylime-git-auth** *(optional)* — A demo-oriented git server that only lets attested agents clone. See [keylime-git-server.md](keylime-git-server.md).

## Network Ports

All ports use mTLS with certificates from the auto-generated PKI in `/var/lib/keylime/tls/`.

- **8891** — Registrar API (agent registration)
- **8881** — Verifier API (attestation, enrollment)
- **8893** — Auto-enroll endpoint (agents POST their measured boot state)
- **443** — Git HTTP server (mTLS, agents only; see [keylime-git-server.md](keylime-git-server.md))

## System Users & File Locations

Two system accounts are created: `keylime` (runs all services, owns `/var/lib/keylime`) and the `tss` group (access to `/dev/tpmrm0`).

State and configuration lives in:

- `/var/lib/keylime/` — Keylime state (SQLite databases for registrar & verifier)
- `/var/lib/keylime/tls/` — Auto-generated TLS PKI (CA cert, server/client certs & keys)
- `/etc/keylime/` — Configuration files (`registrar.conf`, `verifier.conf`, `tenant.conf`, `ca.conf`, `logging.conf`)

## Module Structure

The configuration is composed of two Nix modules:

- **`system-manager/tpm2.nix`** — Simplified port of the NixOS `security.tpm2` module. Manages udev rules and environment variables for TPM access. Does *not* manage kernel modules (the host kernel must have TPM support built-in or loaded).

- **`system-manager/keylime.nix`** — All Keylime services: registrar, verifier, TLS auto-generation, auto-enrollment daemon, and the optional attestation-gated git server. Service definitions, option declarations, and shared helpers all come from `modules/lib/keylime-shared.nix`.

These are wired together in `flake.nix`:

```nix
systemConfigs.default = system-manager.lib.makeSystemConfig {
  modules = [
    ./system-manager/tpm2.nix
    ./system-manager/keylime.nix
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      services.keylime = {
        enable = true;
        registrar.enable = true;
        verifier.enable = true;
        autoEnroll.enable = true;
        gitServer.enable = true;
      };
    }
  ];
};
```

---

# Applying to a Fresh Ubuntu Machine

## Prerequisites

- A **local machine** with [Nix](https://nixos.org/nix) installed (with flakes enabled)
- A **target Linux** `x86_64` machine (e.g. Ubuntu, Debian) reachable via SSH as `root`
- **Network access** from agent machines to ports 8891, 8881, and 8893 on the target

Ensure flakes are enabled on your local machine (add to `/etc/nix/nix.conf` or `~/.config/nix/nix.conf`):

```ini
experimental-features = nix-command flakes
```

Nix does **not** need to be installed on the target machine — system-manager copies the entire closure over SSH.

## Step 1: Clone the Repository

```bash
git clone <repository-url> nixos-android-builder
cd nixos-android-builder
```

## Step 2: Build and Deploy

From your local machine, build and deploy to the target in a single command:

```bash
nix run github:numtide/system-manager -- \
  --target-host root@<server-ip> switch --flake .#default
```

This builds the system-manager closure locally (including the Keylime Python package, measured boot policy, TLS certificate generator, and auto-enrollment daemon), copies it to the target over SSH, and activates it.

Activation will:

1. Create the `keylime` user/group and `tss` group
2. Install udev rules for TPM device access and trigger a reload
3. Write Keylime configuration files to `/etc/keylime/`
4. Set TPM2 TCTI environment variables
5. Start the `keylime-tls` service (generates the PKI on first run)
6. Start the `keylime-registrar` service
7. Start the `keylime-verifier` service
8. Start the `keylime-auto-enroll` daemon

## Step 3: Verify

Check that all services are running:

```bash
systemctl status keylime-tls keylime-registrar keylime-verifier keylime-auto-enroll
```

Verify the TLS certificates were generated:

```bash
ls -la /var/lib/keylime/tls/
```

Test the registrar API:

```bash
curl -k https://127.0.0.1:8891/v2.5/agents/
```

(This will fail with a TLS client certificate error, which is expected — it confirms the registrar is listening and enforcing mTLS.)

## Step 4: Open Firewall Ports

If you are running `ufw` or `iptables`, ensure the required ports are accessible from the agent network:

```bash
sudo ufw allow 8891/tcp   # Registrar (TLS)
sudo ufw allow 8881/tcp   # Verifier (TLS)
sudo ufw allow 8893/tcp   # Auto-enroll (TLS)
sudo ufw allow 443/tcp   # Git server (mTLS, agents only)
```

## Step 5: Distribute the CA Certificate

Agents need the server's CA certificate to establish mTLS. Copy `/var/lib/keylime/tls/ca-cert.pem` to your agent machines (it is baked into the agent's boot configuration via `/boot/attestation-server.json`).

---

# Re-applying / Updating

To update the server after pulling new changes, re-run the same command:

```bash
git pull
nix run github:numtide/system-manager -- \
  --target-host root@<server-ip> switch --flake .#default
```

System-manager will reconcile the running state with the new configuration, restarting services as needed.

# Deactivating

To remove the system-manager managed services, run on the target:

```bash
/nix/var/nix/profiles/system-manager/bin/deactivate
```

This stops the managed services and removes the configuration files, but does not remove Nix itself or the `/var/lib/keylime` state directory.
