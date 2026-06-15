# Contributing

## Quick Reference

| Task | Command |
|------|---------|
| Build disk image | `nix build .#image` |
| Run builder VM | `nix run .#run-vm` |
| Run desktop VM | `nix run .#run-desktop-vm` |
| Run all checks | `nix flake check` |
| Format code | `nix fmt` |
| Enter dev shell | `nix develop` |
| Build docs (HTML) | `nix build .#book-html` |
| Build docs (HTML+PDF) | `nix run .#build-book` |
| Preview docs | `nix run .#preview-book` |

## Development Workflow

1. Edit the relevant module(s) in `modules/`
2. Build: `nix build .#image`
3. Test in a VM: `nix run .#run-vm`
4. Run checks: `nix flake check`
5. Format: `nix fmt`

## Running Tests

The repository ships NixOS VM tests that boot built images and verify the build environment, Secure Boot enrollment, dm-verity, and more.

Run the core integration test:

```bash
$ nix build -L .#checks.x86_64-linux.integration
```

Tests are only re-run when inputs change. Pass `--keep-vm-state` to preserve VM state between runs for iterative debugging.

Additional tests cover the disk installer, keylime attestation, and auto-enrollment:

```bash
$ nix build -L .#checks.x86_64-linux.installer
$ nix build -L .#checks.x86_64-linux.installerInteractive
$ nix build -L .#checks.x86_64-linux.keylime
$ nix build -L .#checks.x86_64-linux.keylime-auto-enroll
```

The `keylime-auto-enroll` test exercises the full auto-enrollment flow: agent registration, measured boot reporting, daemon-driven enrollment, and attestation persistence across 5 reboots.

## Building Specific Outputs

```bash
# Images
nix build .#image                    # Builder image
nix build .#installer-image          # Disk installer
nix build .#desktop-installer-image  # Desktop installer

# Individual packages
nix build .#keylime
nix build .#keylime-agent
nix build .#attestation-ctl
```

## Project Structure

```
flake.nix                     # Flake definition, all NixOS configurations
configuration.nix             # Builder system config (site-specific)
desktop-configuration.nix     # Desktop system config (site-specific)

modules/                      # NixOS modules (core of the project)
├── image.nix                 # Disk image layout & build (largest module)
├── android-build-env.nix     # AOSP build toolchain
├── fhsenv.nix                # FHS compatibility layer
├── keylime.nix               # Keylime server (registrar/verifier)
├── keylime-agent.nix         # Keylime TPM attestation agent
├── secure-boot.nix           # Secure Boot / UKI signing
├── credential-storage.nix    # TPM-encrypted credential storage
├── yubikey-auth.nix          # YubiKey / U2F PAM authentication
├── unattended.nix            # Unattended build pipeline
└── ...                       # base, debug, fatal-error, etc.

packages/                     # Custom Nix packages
├── keylime/                  # Keylime server + measured boot policy
├── disk-installer/           # Disk image installer
├── fhsenv/                   # FHS compatibility wrapper
├── secure-boot-scripts/      # Key generation, signing, enrollment
└── ...

system-manager/               # Keylime server for non-NixOS hosts
tests/                        # NixOS integration tests
docs/                         # Documentation (Pandoc → PDF)
```

## Documentation

Docs are in `docs/chapters/` as Markdown/QMD, built into an HTML site + PDF book via [Quarto](https://quarto.org). Mermaid diagrams render client-side in HTML, via chromium for PDF (typst). NixOS options are auto-generated from module declarations via a Lua filter.

```bash
nix build .#book-html        # hermetic HTML site → result/
nix run .#build-book          # HTML + PDF → docs/_output/
nix run .#preview-book        # live reload
```

## Security Notes

- **Never commit keys** — `keys/` is gitignored
- The UKI signing script runs outside Nix to avoid leaking keys into `/nix/store`
- Debug mode gives unauthenticated root — don't enable in production
