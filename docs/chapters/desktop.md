# Desktop Variant {#sec-desktop}

A persistent NixOS desktop, intended for physical hardware.

## Prerequisites

- [ ] Nix installed on your local machine
- [ ] Git checkout of this repository
- [ ] USB stick (≥ 4 GB)
- [ ] Target machine with UEFI, Secure Boot support, and a disk to install to

## Build

```bash
nix build -L .#desktop-installer-image
install -m 600 result/disk-installer.raw desktop-installer.raw
```

## Customise

Edit `desktop-configuration.nix`:

- [ ] Set YubiKey public keys in `yubikeys.groupA` (or clear for password auth)
- [ ] Set `nixosAndroidBuilder.debug = false` for production

## Sign & Flash

```bash
nix run .#configure-disk-image -- sign --keystore ./keys --device desktop-installer.raw
nix run .#configure-disk-image -- status --keystore ./keys --device desktop-installer.raw
sudo dd bs=1M status=progress if=desktop-installer.raw of=/dev/sdX
sudo sync
```

- [ ] Both "Installer" and "Payload" show "✓ Signed and verified"

## Prepare Target UEFI

- [ ] Enable Secure Boot
- [ ] Put Secure Boot into **Setup Mode** (clear existing keys)
- [ ] Set USB as first boot device
- [ ] Save and reboot

## Install

- [ ] Boot from USB — installer appears on tty2
- [ ] Select target disk (or auto-installs if pre-configured)
- [ ] Wait for copy to complete
- [ ] Remove USB when prompted, press Enter to reboot

## First Boot

Two automatic reboots:

1. **Boot 1**: Secure Boot keys auto-enroll → automatic reboot
2. **Boot 2**: `systemd-repart` grows root partition → normal boot

## Verify

- [ ] `tuigreet` login screen appears
- [ ] `bootctl status` shows `Secure Boot: enabled (user)`
- [ ] `df -h /` shows root using the full disk
- [ ] Network is up (`ip addr`)
- [ ] Data persists across `systemctl reboot`
