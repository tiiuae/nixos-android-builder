# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ddrescue2gauge() {
    local total="$1"
    local pct="0"
    local copied="0 B"
    local rate="0 B/s"
    local remaining="unknown"
    local errors="0"

    while true; do
        local rc=0
        IFS= read -r -t 60 line || rc=$?
        if [ "$rc" -gt 128 ]; then
            # read timed out — ddrescue may be stalled
            echo "WARNING: no ddrescue output for 60s" >&5
            continue
        elif [ "$rc" -ne 0 ]; then
            break  # EOF — ddrescue finished
        fi
        if [[ "$line" =~ pct\ rescued:[[:space:]]*([0-9.]+)% ]]; then
            pct="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ rescued:[[:space:]]*([0-9.]+[[:space:]]*[kMGT]?B) ]]; then
            copied="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ current\ rate:[[:space:]]*([0-9.]+[[:space:]]*[kMGT]?B/s) ]]; then
            rate="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ remaining\ time:[[:space:]]*([^,[:space:]]+) ]]; then
            remaining="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ read\ errors:[[:space:]]*([0-9]+) ]]; then
            errors="${BASH_REMATCH[1]}"
        fi

        if [[ "$line" =~ time\ since\ last\ successful\ read ]]; then
            pct_int=${pct%.*}
            echo "$pct_int"
            echo "XXX"
            echo "Copied: ${copied} of ${total}"
            echo "Rate: ${rate}"
            echo "Estimated Time Remaining: ${remaining}"
            echo "Errors: ${errors}"
            echo "XXX"
        fi
    done
}

select_disk() {
    if ! disk_json="$(lsblk --json --nodeps --output NAME,SIZE,TYPE,MODEL 2>/dev/null)"; then
        echo "Error: Failed to retrieve disk information" | tee /run/fatal-error >&5
        exit 1
    fi

    menu_options=()
    while IFS='|' read -r name size model; do
        device="/dev/$name"
        if [ "$device" = "$1" ]; then
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
        --title "Disk Selection" \
        --default-item "${menu_options[0]}" \
        --nocancel \
        --menu "Select a disk to install to. All existing data on it will be WIPED!" \
        20 60 10 \
        "${menu_options[@]}"
    )"
    if [ -z "$selected_disk" ]; then
        selected_disk="${menu_options[0]}"
    fi
    echo "$selected_disk"
}

# Save current VT so we can restore it later.
original_vt="$(fgconsole 2>/dev/null || echo 1)"

if [ -e /dev/tty2 ]; then
    chvt 2
fi

if command -v systemd-cat >/dev/null 2>&1; then
    exec 4> >(systemd-cat -p info)
    exec 5> >(systemd-cat -p err)
else
    exec 4>> /run/installer.log
    exec 5>> /run/installer.log
fi

echo -e "\nDisk Installer\n" >&4

if [ ! -t 1 ]; then
    echo "stdout is NOT a tty" | tee /run/fatal-error >&5
    exit 1
fi


echo "Using $INSTALL_SOURCE as installation source" >&4
if [ ! -b "$INSTALL_SOURCE" ]; then
  echo "ERROR: installation source \"$INSTALL_SOURCE\" is not a block device." | tee /run/fatal-error >&5
  exit 1
fi


install_target="$(cat /boot/install_target || true)"
if [ "$install_target" = "select" ] || [ -z "$install_target" ]; then
    own_disk="$(lsblk -npo PKNAME /dev/disk/by-label/DISK-INSTAL)"
    install_target="$(select_disk "$own_disk")"
fi

if [ ! -b "$install_target" ]; then
  echo "ERROR: installation target \"$install_target\" is not a block device." | tee /run/fatal-error >&5
  exit 1
fi

intro_msg="About to install from $INSTALL_SOURCE to $install_target"
echo  "$intro_msg" >&4
if ! dialog --colors --pause "$intro_msg" 10 40 3; then
    echo "User cancelled installation." | tee /run/fatal-error >&5
    exit 1
fi

echo "ensuring that $install_target >= $INSTALL_SOURCE." >&4

INSTALL_SOURCE_size=$(lsblk -bno SIZE -J "$INSTALL_SOURCE" | jq -r '.blockdevices[0].size')
install_target_size=$(lsblk -bno SIZE -J "$install_target" | jq -r '.blockdevices[0].size')

if [ "$install_target_size" -lt "$INSTALL_SOURCE_size" ]; then
    echo "Error: $install_target ($install_target_size) is smaller than $INSTALL_SOURCE ($INSTALL_SOURCE_size)" >&5
    exit 1
else
    echo "OK: $install_target is at least as large as $INSTALL_SOURCE" >&4
fi

msg_copy="Copying source disk $INSTALL_SOURCE to target disk $install_target"
echo $msg_copy >&4
ddrescue -f -v --timeout=300s "$INSTALL_SOURCE" "$install_target" 2>&1 \
    | ddrescue2gauge "$(lsblk -no SIZE "$INSTALL_SOURCE")" \
    | dialog --colors --title "$msg_copy" --gauge "Starting..." 16 60 10


# Relocate the GPT backup table to the end of the (now larger) target disk.
# sgdisk -e is non-interactive and purpose-built for this, unlike parted
# which requires fragile interactive prompt handling.
sgdisk -e "$install_target"
sync

echo 1 > /run/installer_done  # marker file for automated tests

msg_done="Installation to $install_target done.\n\nPlease remove the installation media before pressing enter to reboot."
echo "$msg_done" >&4
dialog --colors --ok-button " Reboot " --msgbox "$msg_done" 10 60

chvt "$original_vt"

systemctl reboot --no-block --force
