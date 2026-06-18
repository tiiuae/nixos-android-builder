#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

# Given a read-only disk image:
# - copy it to a temporary, writable location
# - find its ESP partition
# - sign the default EFI application on it - usually our Unified Kernel Image (UKI)
# - copy update bundles for Secure Boot enrollment into EFI/KEYS.
# - move the image to the repositories toplevel directory and inform the user
#
# Using mtools and raw image files has the advantage of neither
# requiring root nor any daemons, so it works in restricted build
# environments such as the nix sandbox or different CI runners.
set -euo pipefail

keystore="${keystore:-$PWD/keys}"
target_image_readonly_file="$1"
target_image_out_file="$PWD/$(basename "$target_image_readonly_file")"
target_image_temp_file="$(mktemp --suffix "android-builder.raw")"
temp_dir=$(mktemp -d --suffix "efi")
esp_uki="EFI/BOOT/BOOTX64.EFI"
esp_keystore="EFI/KEYS"

cleanup() {
    rm -rf "$temp_dir"
}
trap "cleanup" EXIT

if [ ! -d "$keystore" ]
then
    echo >&2 "Directory ${keystore} does not exist. Please run \`create-signing-keys\` to create it."
    exit 1
else
    echo >&2 "Using keystore ${keystore}".
fi
echo >&2 "Copying $target_image_readonly_file to $target_image_temp_file"
install -T "$target_image_readonly_file" "$target_image_temp_file"

echo >&2 "Searching ESP partition offset in $target_image_temp_file"
esp_offset="$(
  parted \
    --script \
    --json \
    "$target_image_temp_file" \
    -- unit B print \
    | \
 jq -r '
   .disk.partitions[]
   | select(.flags and (.flags | contains(["esp"])))
   | .start
   | rtrimstr("B")'
)"

mtools_args="-i $target_image_temp_file@@$esp_offset"
mcopy_args="$mtools_args -o"

echo >&2 "Copying $esp_uki from the image to $temp_dir/$esp_uki"
mkdir -p "$temp_dir/$(dirname "$esp_uki")"
mcopy $mtools_args "::$esp_uki" "$temp_dir/$esp_uki"

echo >&2 "Signing $temp_dir/$esp_uki"
sbsign \
  --key "$keystore/db.key" \
  --cert "$keystore/db.crt" \
  "$temp_dir/$esp_uki" \
  --output "$temp_dir/$esp_uki"

echo >&2 "Copying $temp_dir/$esp_uki back to the image, into $esp_uki"
mcopy $mcopy_args "$temp_dir/$esp_uki" "::$esp_uki"

echo >&2 "Copying certificates from $keystore to the image, into $esp_keystore"
mmd $mtools_args "::$esp_keystore"
mcopy $mcopy_args "$keystore"/{PK,KEK,db}.auth "::$esp_keystore"


echo >&2 "Moving the image from $target_image_temp_file to $target_image_out_file"
mv "$target_image_temp_file" "$target_image_out_file"

echo >&2 "Done. You can now flash the signed image:"
echo "$target_image_out_file"
