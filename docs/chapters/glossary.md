# Glossary {#sec-glossary}

AK
:   Attestation Key. A TPM-resident key used by the Keylime agent to sign attestation quotes.

AOSP
:   Android Open Source Project. The publicly available source code for Android maintained by Google.


Attestation
:   The process of a remote party (verifier) confirming that a machine is running expected software on genuine hardware, based on TPM-signed measurements.


dm-verity
:   A Linux kernel feature that provides transparent integrity checking of block devices using a Merkle tree.


EFI/UEFI
:   Unified Extensible Firmware Interface. The modern firmware interface between the operating system and hardware, replacing legacy BIOS.


EK
:   Endorsement Key. A unique, manufacturer-provisioned key in the TPM that serves as the device's hardware identity. Used by the keylime agent to derive a stable UUID.


erofs
:   Enhanced Read-Only File System. A compressed, read-only filesystem used for the immutable store partition.


ESP
:   EFI System Partition. A FAT-formatted partition containing files needed to boot.


FHS
:   Filesystem Hierarchy Standard. A standard defining the directory structure and contents of traditional Linux systems (e.g., `/bin`, `/lib`, `/usr`).


Flake
:   A Nix mechanism for defining reproducible projects with locked dependencies. This project is a flake (see `flake.nix`).


initrd
:   Initial RAM Disk. A temporary root filesystem loaded into memory during boot, used to prepare the real root filesystem.


Keylime
:   An open-source TPM-based remote attestation framework. Consists of an agent, registrar, and verifier.


keylime_tenant
:   Keylime's upstream CLI tool for enrolling and managing agents with the verifier.


KVM
:   Kernel-based Virtual Machine. Linux kernel module for hardware-assisted virtualization.


LUKS
:   Linux Unified Key Setup. The standard system for Linux disk encryption.


lunch
:   AOSP's build configuration selector. Chooses the target product, variant, and build type.


mTLS
:   Mutual TLS. A TLS connection where both client and server authenticate with certificates. Used between keylime components.


Nix
:   A purely functional package manager and build system that enables reproducible, declarative builds.


NixOS
:   A Linux distribution built on Nix, where the entire system configuration is declared in Nix expressions.


nixpkgs
:   The main repository of Nix packages, containing build instructions for tens of thousands of software packages.


NvPCR
:   Non-Volatile PCR anchoring. A systemd mechanism (`systemd-tpm2-setup.service`) that extends PCR 9 at runtime, not captured in the UEFI event log.


PAM
:   Pluggable Authentication Modules. The Linux framework for pluggable authentication.


pam_u2f
:   A PAM module for U2F/FIDO2 authentication with hardware tokens such as YubiKeys.


PCR
:   Platform Configuration Register. A set of SHA-256 registers inside the TPM that accumulate measurements of firmware, boot configuration, and software components. Used for attestation and credential binding.


PK/KEK/DB
:   Platform Key, Key Exchange Key, and Signature Database. Keys used by UEFI Secure Boot to verify boot components.


QEMU
:   A machine emulator and virtualizer. Used for VM-based testing of builder and installer images.


repo
:   Google's tool for managing multiple Git repositories, used extensively in AOSP development.


SBOM
:   Software Bill of Materials. A formal inventory of all components and dependencies in a piece of software.


SCRTM
:   Static Root of Trust for Measurement. The initial firmware code that begins the TPM measurement chain at boot.


Secure Boot
:   A UEFI feature that ensures only cryptographically signed software can be booted.


Setup Mode
:   A Secure Boot state where custom keys can be enrolled. The firmware accepts new keys without signature verification.


SLSA
:   Supply-chain Levels for Software Artifacts. A tiered framework for verifying build artifact integrity and provenance.


SOPS
:   Secrets OPerationS. A tool for encrypting/decrypting secrets files, supporting age, GPG, and cloud KMS backends.


system-manager
:   A tool by numtide that applies NixOS-style module configurations to non-NixOS Linux distributions. Used to deploy the attestation server.


systemd-creds
:   A systemd mechanism for encrypting and decrypting credentials, optionally bound to the TPM.


systemd-pcrphase
:   A systemd service that extends PCR 11 with boot phase strings (`sysinit`, `ready`, etc.) at runtime.


systemd-repart
:   A systemd tool for declaratively creating and managing disk partitions at build time and boot time.


systemd-stub
:   The EFI stub embedded in a Unified Kernel Image. Measures UKI PE sections into PCR 11 and event tags into PCR 9.




TOFU
:   Trust on First Use. A security model where the first connection is accepted without verification; subsequent connections are validated against the initial state.


TPM
:   Trusted Platform Module. A dedicated security chip that provides hardware-based cryptographic functions and key storage.


tuigreet
:   A TUI-based login greeter used by the desktop variant.


UKI
:   Unified Kernel Image. A single EFI executable containing the Linux kernel, initrd, and boot parameters.


USBGuard
:   A Linux framework for blocking unauthorized USB devices. Used during unattended builds to prevent data exfiltration.

