# Building & Signing Images {#sec-building-images}

## Build

Build the disk image. Dependencies are fetched from [cache.nixos.org](https://cache.nixos.org); subsequent runs are cached.

```bash
nix build --print-build-logs .#image
```

::: {.callout-tip}
[nix-output-monitor](https://github.com/maralorn/nix-output-monitor) gives better build progress. Install with `nix shell nixpkgs#nom`, then use `nom build` instead.
:::

The result is a raw disk image (~2.7 GB) with a full partition table and NixOS closure.

## Sign

`configure-disk-image sign` signs the UKI and copies Secure Boot enrollment bundles. It runs outside the Nix sandbox to avoid leaking keys into `/nix/store`.

Copy the image out of the read-only store, then sign:

```bash
install -m 600 result/*.raw .
nix run .#configure-disk-image -- sign --keystore ./keys --device *.raw
```

## Configure Attestation Server

The image needs to know how to reach the attestation server. This writes the server address and CA certificate to the ESP:

```bash
nix run .#configure-disk-image -- set-attestation-server \
    --ip 10.0.0.1 \
    --ca-cert /path/to/ca-cert.pem \
    --device *.raw
```

If skipped, the keylime agent will fail to start on boot. See @sec-agent-config for the JSON schema.

See @sec-attestation-server for deploying the server itself.

## Flash

Flash the signed image to a USB stick or external drive:

```bash
sudo dd bs=1M status=progress if=*.raw of=/dev/sdX
sudo sync
```

Use `lsblk` to identify the target device.

Enable Secure Boot Setup Mode in the target machine's firmware before first boot. This is needed for automatic key enrollment. After enrollment, Setup Mode is not needed again unless keys are rotated.
