#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
IFS=',' read -ra steps <<< "${STEPS}"
total=${#steps[@]}
chvt 2

# Initial setup - only once
clear
width=$(tput cols)
lines=$(tput lines)

# Set up colors and scroll region once
tput csr 3 "$lines"
tput cup 3 0
tput setaf 0
tput setab 7
tput ed

update_header() {
    local current=$1 step=$2
    local divider=$(printf '─%.0s' $(seq 1 "$width"))
    # Save cursor, exit scroll region temporarily
    tput sc
    tput csr 0 "$lines"
    # Draw header
    tput cup 0 0
    tput setaf 7; tput setab 4
    printf "%-${width}s" "$divider"
    printf "%-${width}s" " $current/$total: $step"
    printf "%-${width}s" "$divider"
    # Restore scroll region and cursor
    tput csr 3 "$lines"
    tput rc
    tput setaf 0; tput setab 7
}

for i in "${!steps[@]}"; do
    step="${steps[$i]}"
    current=$((i + 1))

    update_header "$current" "$step"

    # Print step divider in scroll area (so prior steps are delineated)
    printf '\n%s\n' "── Step $current: $step ──"

    cmd="${step#root:}"
    if [[ "$step" == root:* ]]; then
        cmd="sudo $cmd"
    fi
    script -q -c "$cmd" /dev/null 2>&1 | tee >(systemd-cat -t "step-$current")

    tput setaf 0
    tput setab 7
done

tput csr 0 "$lines"
tput sgr0
tput cup "$lines" 0
chvt 1
systemctl poweroff --no-block --force
