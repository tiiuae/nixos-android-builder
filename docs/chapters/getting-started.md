# Getting Started {#sec-getting-started}

## Requirements

* A **local machine** with [Nix](https://nixos.org/nix) installed, building for `x86_64-linux`.
    - ~4 GB memory for evaluation
    - ~30 GB disk space for dependencies and images

* A **USB mass storage** device (~3 GB) to transfer the image.

* A **target machine** for building Android:
    - ~64 GB memory
    - ~250 GB free disk space
    - UEFI with Secure Boot in Setup Mode

* A **git checkout** of this repository. Commands assume the repository root unless stated otherwise.

* *(Optional)* An **attestation server** running Keylime. See @sec-attestation-server. Not required for @sec-vm-testing.

## Generate Secure Boot Keys

The `create-signing-keys` helper generates a PK/KEK/DB key set in `keys/`:

```bash
nix run .#create-signing-keys
```

These keys are required for Secure Boot signing and enrollment. They **must not** be committed plain-text. Tools such as [SOPS](https://github.com/getsops/sops/) can manage them securely.
