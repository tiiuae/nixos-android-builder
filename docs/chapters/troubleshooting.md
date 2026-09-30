<!--
SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Troubleshooting {#sec-troubleshooting}

## Secure Boot

**"Secure Boot is neither active nor in setup mode" error on boot**

Applies to both the builder and the desktop image; the check runs on every boot.

1. Enter firmware setup (F2/F12/Del during POST)
2. Navigate to Security → Secure Boot → Enable
3. Save and reboot

**"Secure Boot is in setup mode but no keys are available to enroll" error on boot**

The firmware keys were cleared after the first enrollment, which removed the keys from the ESP. Either restore the previous keys in firmware settings, or copy the keys back to the ESP and reboot to enroll them again:

```bash
nix run .#configure-disk-image -- sign --keystore ./keys --device /dev/sdX
```

**Keys won't enroll**

Ensure Setup Mode, not User Mode with existing keys:

1. Security → Secure Boot → Key Management → Clear All Keys / Reset to Setup Mode
2. Save and reboot

**Boot fails after key enrollment**

Re-sign with the correct keystore and verify:

```bash
nix run .#configure-disk-image -- status --keystore ./keys --device <image>
```

## Boot

**"dm-verity: Hash verification failed"** — Store partition corrupted. Rebuild and reflash.

**Drops to emergency shell** — Check `journalctl -e`. Common causes: disk too small (needs 250 GB), hardware compatibility.

## Android Build

**`fetch-android` fails with network errors** — For air-gapped environments:

```bash
fetch-android --repo-manifest-url=https://your-internal-mirror/platform/manifest
```

**`build-android` fails with "command not found"** — Verify FHS bind mounts:

```bash
mount | grep -E '/bin|/lib'
ls -la /bin/bash /lib/ld-linux-x86-64.so.2
```

**Build outputs disappeared after reboot** — Enable artifact storage: set `nixosAndroidBuilder.artifactStorage.enable = true`. See @sec-running-builds.

## Attestation

**Agent registers but is not enrolled** (see @sec-attestation-protocol for ports and PKI) — Check `journalctl -u keylime-auto-enroll`. The daemon waits for both registration AND a measured boot report. Common causes:

- `report-measured-boot-state` service failed (check `journalctl -u report-measured-boot-state`)
- mTLS certificate issues
- Port 8893 not reachable

**Agent enrolled but fails attestation** — Delete enrollment and re-enroll:

```bash
keylime_tenant -c delete -u <agent-uuid> -v <verifier-ip> -vp 8881
```

## VM Testing

**"KVM not available"** — Enable VT-x/AMD-V in BIOS. Verify: `lsmod | grep kvm`

**Can't exit VM** — `systemctl poweroff` or close the QEMU window.
