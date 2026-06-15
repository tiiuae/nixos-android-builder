# Disk Installer {#sec-disk-installer}

The installer image contains a minimal ESP plus the builder image as payload. It boots and flashes the payload to a local disk.

## Build & Sign

```bash
nix build -L .#installer-image
install -m 600 result/disk-installer.raw .
nix run .#configure-disk-image -- sign --keystore ./keys --device disk-installer.raw
```

The `sign` sub-command accepts flags:

- `--installer` — sign only the installer UKI
- `--payload` — sign only the payload UKI
- `--no-auto-enroll` — skip copying Secure Boot enrollment bundles

## Configure Install Target

Interactive (user selects disk at boot):

```bash
nix run .#configure-disk-image -- set-target --target select --device disk-installer.raw
```

Automatic (no prompt):

```bash
nix run .#configure-disk-image -- set-target --target /dev/vda --device disk-installer.raw
```

## Verify Configuration

```bash
nix run .#configure-disk-image -- status --keystore ./keys --device disk-installer.raw
```

## Test in a VM

```bash
nix run .#installer-vm
```
