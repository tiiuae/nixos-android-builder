# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

select_disk() {
    if ! disk_json="$(lsblk --json --nodeps --output NAME,SIZE,TYPE,MODEL 2>/dev/null)"; then
        echo "Error: Failed to retrieve disk information" | tee /run/fatal-error >&5
        exit 1
    fi

    own_disk="$(lsblk -ndo PKNAME /dev/disk/by-label/BOOT)"

    menu_options=()
    while IFS='|' read -r name size model; do
        device="/dev/$name"
        if [ "$name" = "$own_disk" ]; then
            continue
        fi
        description="$size   (${model:-Unknown model})"
        menu_options+=("$device" "$description")
    done < <(echo "$disk_json" | jq -r '.blockdevices[] | select(.type == "disk") | "\(.name)|\(.size)|\(.model // "Unknown")"')

    if [ ${#menu_options[@]} -eq 0 ]; then
        echo "Error: No disks found" | tee /run/fatal-error >&5
        exit 1
    fi

    selected_disk="$(
    dialog \
        --output-fd 1 \
        --colors \
        --title "Artifact Storage" \
        --default-item "${menu_options[0]}" \
        --nocancel \
        --menu "Select a disk to store build artifacts in. All existing data on it will be WIPED!" \
        20 60 10 \
        "${menu_options[@]}"
    )"
    # timeout leads to an empty result
    if [ -z "$selected_disk" ]; then
        selected_disk="${menu_options[0]}"
    fi
    echo "$selected_disk"
}

chvt 2
exec 4> >(systemd-cat -p info)
exec 5> >(systemd-cat -p err)

echo "Preparing artifact storage" >&4

LABELED_DEVICE="/dev/disk/by-label/$DISK_LABEL"
if [ ! -b "$LABELED_DEVICE" ]; then
    echo "No existing, $LABELED_DEVICE found." >&4

    artifacts_target="$(cat /boot/storage_target || true)"
    if [ -z "$artifacts_target" ]; then
        echo "No configured device for $LABELED_DEVICE found. Asking user" >&4
        artifacts_target="$(select_disk)"
    fi
    echo "Formatting: $artifacts_target" >&4
    mkfs.ext4 -L "$DISK_LABEL" "$artifacts_target"
else
    echo "Found $LABELED_DEVICE, nothing to do" >&4
fi
chvt 1
