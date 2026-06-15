# Contributing {#sec-contributing .appendix}

## Quick Reference

| Task | Command |
|------|---------|
| Build disk image | `nix build .#image` |
| Run builder VM | `nix run .#run-vm` |
| Run desktop VM | `nix run .#run-desktop-vm` |
| Run all checks | `nix flake check` |
| Format code | `nix fmt` |
| Enter dev shell | `nix develop` |
| Build this manual | `nix run .#build-book` |

## Development Workflow

1. Edit modules in `modules/`
2. Build: `nix build .#image`
3. Test in VM: `nix run .#run-vm`
4. Run checks: `nix flake check`
5. Format: `nix fmt`

## Tests

NixOS VM tests verify the build environment, Secure Boot, dm-verity, installer, and attestation:

```bash
nix build -L .#checks.x86_64-linux.integration
nix build -L .#checks.x86_64-linux.installer
nix build -L .#checks.x86_64-linux.installerInteractive
nix build -L .#checks.x86_64-linux.keylime
nix build -L .#checks.x86_64-linux.keylime-auto-enroll
```

Tests are only re-run when inputs change. Pass `--keep-vm-state` to preserve VM state for iterative debugging.

## Project Structure

```
flake.nix                     # Flake definition
configuration.nix             # Builder config (site-specific)
desktop-configuration.nix     # Desktop config (site-specific)

modules/                      # NixOS modules
├── image.nix                 # Disk image layout (largest module)
├── android-build-env.nix     # AOSP build toolchain
├── fhsenv.nix                # FHS compatibility layer
├── keylime.nix               # Keylime server
├── keylime-agent.nix         # Keylime agent
├── secure-boot.nix           # Secure Boot / UKI
├── credential-storage.nix    # TPM credential storage
├── yubikey-auth.nix          # YubiKey PAM
├── unattended.nix            # Unattended build pipeline
└── ...

packages/                     # Custom Nix packages
system-manager/               # Keylime server for non-NixOS
tests/                        # NixOS integration tests
docs/                         # This manual (Quarto)
```

## Security Notes

- **Never commit keys** — `keys/` is gitignored
- UKI signing runs outside Nix to avoid leaking keys into `/nix/store`
- Debug mode gives unauthenticated root — production must disable it
