# NixOS Android Builder

A custom NixOS system to build Android Open Source Project in an ephemeral, attested environment.

- **Ephemeral** — build state is encrypted with a fresh random key on each boot
- **Attested** — TPM-based remote attestation via [Keylime](https://keylime.dev/) ensures only unmodified machines can operate
- **Secure Boot** — signed Unified Kernel Image (UKI) with dm-verity-checked store partition
- **Declarative** — fully defined in Nix, reproducible from source

```
┌─────────────────┐       ┌───────────────────────┐       ┌──────────────────┐
│  Local Machine   │       │  Attestation Server   │       │ Builder Machine  │
│                  │       │                       │       │                  │
│  nix build       │       │  keylime-registrar    │◄─────►│  keylime-agent   │
│  sign & flash    │       │  keylime-verifier     │       │  TPM 2.0         │
└────────┬─────────┘       └───────────────────────┘       └────────▲─────────┘
         │                                                          │
         └──────────────── flash via USB ───────────────────────────┘
```

## Quick Start

```bash
nix run .#create-signing-keys          # generate Secure Boot keys in ./keys/
nix build .#image                       # build the disk image
install -m 600 result/*.raw .           # copy out of the read-only nix store
nix run .#configure-disk-image -- sign --keystore ./keys --device *.raw
sudo dd bs=1M status=progress if=*.raw of=/dev/sdX && sudo sync
```

See the full manual via `nix build .#book-html` or `nix run .#preview-book`.

## Try in a VM

```bash
nix run .#run-vm
```

## Tests

```bash
nix flake check
```

## Documentation

Build the manual:

```bash
nix build .#book-html        # HTML site in result/
nix run .#build-book          # HTML + PDF to docs/_output/
nix run .#preview-book        # live reload dev server
```

See also [CONTRIBUTING.md](./CONTRIBUTING.md) for development workflow and testing.
