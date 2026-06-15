# Running Android Builds {#sec-running-builds}

After booting, you get a shell with the Android build toolchain.

The scripts below (`fetch-android`, `build-android`, etc.) are reference implementations shipped as convenience wrappers. They demonstrate the intended workflow but can be replaced or extended for specific distribution needs.

## Fetch Source

```bash
fetch-android
```

Uses `repo` to clone AOSP to `/var/lib/build/source`. If multiple branches are configured via `nixosAndroidBuilder.build.branches`, `select-branch` presents a menu on boot.

Run `fetch-android --help` for flags (manifest URL, branch, source directory, git identity).

## Build

```bash
build-android
```

Run `build-android --help` for flags (lunch target, source directory).

Lower-level tools (`lunch`, `m`, `ninja`) are available after loading Android's `envsetup.sh`:

```bash
cd /var/lib/build/source
source build/envsetup.sh
```

See [upstream documentation](https://source.android.com/docs/setup/build/building) for details.

## SBOM Generation

```bash
android-sbom
```

Generates a Software Bill of Materials in `/var/lib/build/source/out/soong/sbom` using [upstream SBOM facilities](https://source.android.com/docs/setup/create/create-sbom).

## Source Measurement

```bash
android-measure-source
```

Hashes all files across all git repositories in the checkout, producing `out/source_measurement.txt`.

## Save Build Outputs

Outputs are in `/var/lib/build/source/out` — images in `out/target/product`, logs in `error.log` and `verbose.log.gz`.

Since `/var/lib/build` is ephemeral, outputs are lost on shutdown. To persist them, set `nixosAndroidBuilder.artifactStorage.enable = true`. During boot, a second disk is selected for persistent storage at `/var/lib/artifacts`. It can also be pre-configured:

```bash
nix run .#configure-disk-image -- set-storage --target /dev/sdb --device *.raw
```

The `copy-android-outputs` script copies outputs matching `nixosAndroidBuilder.artifactStorage.contents` to `/var/lib/artifacts`.

## Credential Storage

A TPM-backed credential store persists secrets across reboots (see @sec-credential-storage).

```bash
echo 'my-secret-token' | credential-store add api-token
credential-store list
credential-store show api-token
credential-store remove api-token
```

Credentials can also be added from a file:

```bash
credential-store add api-token ~/token.txt
```

Credentials are bound to PCR 7 (Secure Boot policy) by default. See @sec-options-reference for customization (e.g. adding PCR 11 binding).

## Inspect PCR State

TPM PCR values can be read from sysfs:

```bash
cat /sys/class/tpm/tpm0/pcr-sha256/7
```

On boot, `report-measured-boot-state` sends the measured boot reference state to the attestation server automatically. For debugging:

`measure-boot-state` generates the reference state from the UEFI event log:

```bash
measure-boot-state -o /tmp/refstate.json
```

`debug-measured-boot-state` diagnoses attestation failures:

```bash
debug-measured-boot-state save                    # before reboot
debug-measured-boot-state                         # after reboot — auto-detects saved state
debug-measured-boot-state diagnose -r enrolled.json  # compare against enrolled state
```

## Reset to Initial State

Reboot. The ephemeral encryption key is lost, rendering all build data inaccessible. The `/var/lib/build` partition is reformatted on next boot.

```bash
systemctl reboot
```

## Updates

Update all dependencies by updating the pinned nixpkgs:

```bash
nix flake update
```

Rebuild the image and run tests (see @sec-contributing) to catch regressions.
