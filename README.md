<!--
SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# NixOS Android Builder

This repository contains a custom Linux system to build Android Open Source Project in a (mostly) ephemeral environment. Our images, based on NixOS, provide a FHS-compatible enviroment that can run upstream Androids toolchain while being flexible and relatively easy to adapt due to the NixOS module system.

We boot into memory while keeping build state that's too big for memory in an ephemeral `/var/lib/build` partition on disk. That partition is encrypted with a fresh random key on each boot.
Persistent, TPM2-bound LUKS partitions store keylime agent state and systemd-encrypted credentials across reboots. A second disk can optionally be used as "artifact storage" for build outputs in air-gapped environments.

See [user-guide.md](./docs/user-guide.md) for usage guidance and [docs.md](./docs/docs.md) for a more detailed description of design considerations, used components limitations, and further work.
