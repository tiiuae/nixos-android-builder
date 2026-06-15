# Attestation Server Setup {#sec-attestation-server}

The `system-manager/` directory turns a stock Linux machine (Ubuntu, Debian, etc.) into a Keylime attestation server — registrar, verifier, auto-enrollment daemon, and an optional attestation-gated git server.

[System-manager](https://github.com/numtide/system-manager) applies NixOS-style module configurations to non-NixOS hosts without replacing the OS.

## What It Runs

- **keylime-registrar** — Accepts agent registrations (EK + AK identity)
- **keylime-verifier** — Continuously attests enrolled agents via TPM quotes
- **keylime-auto-enroll** — Bridges registration and verification; auto-enrolls agents
- **keylime-tls** — Oneshot service; auto-generates a self-signed CA and mTLS PKI
- **keylime-git-nginx** / **keylime-git-auth** *(optional)* — Attestation-gated git server (see @sec-attestation-git-server)

See @sec-attestation-protocol for ports, data flow, and PKI details.

## System Users & File Locations

- `keylime` user — runs all services, owns `/var/lib/keylime`
- `tss` group — TPM device access (`/dev/tpmrm0`)
- `/var/lib/keylime/` — Keylime state (SQLite databases)
- `/var/lib/keylime/tls/` — Auto-generated TLS PKI
- `/etc/keylime/` — Configuration files (`registrar.conf`, `verifier.conf`, `tenant.conf`, `ca.conf`, `logging.conf`)

## Module Structure

Two Nix modules in `system-manager/`:

- `tpm2.nix` — udev rules and environment variables for TPM access (host kernel must have TPM support)
- `keylime.nix` — all Keylime services; shared helpers from `modules/lib/keylime-shared.nix`

Wired in `flake.nix`:

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
      };
    }
  ];
};
```

## Prerequisites

- A **local machine** with Nix installed ([flakes enabled](https://nixos.wiki/wiki/Flakes))
- A **target Linux** `x86_64` machine reachable via SSH as `root`
- **Network access** from agents to the target on ports 8891, 8881, 8893

Nix does not need to be installed on the target.

## Deploy

```bash
git clone <repository-url> nixos-android-builder
cd nixos-android-builder
nix run 'github:numtide/system-manager' -- \
  --target-host root@<server-ip> switch --flake .#default
```

Activation creates the `keylime`/`tss` users, writes config to `/etc/keylime/`, generates the TLS PKI, and starts all services.

## Verify

```bash
systemctl status keylime-tls keylime-registrar keylime-verifier keylime-auto-enroll
ls -la /var/lib/keylime/tls/       # TLS certificates
curl -k https://127.0.0.1:8891/v2.5/agents/   # expect TLS client cert error — confirms registrar is listening
```

## Open Firewall

```bash
sudo ufw allow 8891/tcp   # Registrar (mTLS)
sudo ufw allow 8881/tcp   # Verifier (mTLS)
sudo ufw allow 8893/tcp   # Auto-enroll (server TLS, TOFU)
sudo ufw allow 443/tcp    # Git server (mTLS, optional — only if gitServer.enable is set)
```

## Distribute CA Certificate

Copy `/var/lib/keylime/tls/ca-cert.pem` from the server. It is baked into agent images via `configure-disk-image set-attestation-server` (see @sec-building-images).

## Update

```bash
git pull
nix run 'github:numtide/system-manager' -- \
  --target-host root@<server-ip> switch --flake .#default
```

## Deactivate

On the target:

```bash
/nix/var/nix/profiles/system-manager/bin/deactivate
```

Stops managed services and removes config. Does not remove `/var/lib/keylime` state.
