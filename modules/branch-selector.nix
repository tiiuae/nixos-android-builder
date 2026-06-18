# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.nixosAndroidBuilder.build;

  select-branch = pkgs.writeShellScriptBin "select-branch" ''
    set -euo pipefail

    BRANCHES_FILE="/etc/branches"
    SELECTED_FILE="/tmp/selected-branch"

    if [ ! -f "$BRANCHES_FILE" ]; then
      echo "Error: No branches file found at $BRANCHES_FILE" >&2
      exit 1
    fi

    mapfile -t branches < "$BRANCHES_FILE"

    if [ ''${#branches[@]} -eq 0 ]; then
      echo "Error: No branches configured" >&2
      exit 1
    fi

    if [ ''${#branches[@]} -eq 1 ]; then
      echo "''${branches[0]}" > "$SELECTED_FILE"
      echo "Auto-selected branch: ''${branches[0]}"
      exit 0
    fi

    menu_options=()
    for i in "''${!branches[@]}"; do
      branch="''${branches[$i]}"
      menu_options+=("$branch" "")
    done

    selected_branch="$(
      ${pkgs.dialog}/bin/dialog \
        --output-fd 1 \
        --colors \
        --no-cancel \
        --title "Branch Selection" \
        --default-item "''${branches[0]}" \
        --timeout 30 \
        --menu "Select a branch to build (auto-selects in 30s):" \
        20 60 10 \
        "''${menu_options[@]}"
    )" || true

    if [ -z "$selected_branch" ]; then
      selected_branch="''${branches[0]}"
      echo "Auto-selected branch: $selected_branch"
    fi

    echo "$selected_branch" > "$SELECTED_FILE"
    echo "Selected branch: $selected_branch"
  '';
in
{
  options.nixosAndroidBuilder.build.branches = lib.mkOption {
    description = ''
      List of valid branches that can be selected for building.
      If only one branch is specified, it will be selected automatically.
      If more than one branch is specified, a dialog menu will be shown for 30 seconds.
      First entry will be the default if no other one is selected.
    '';
    type = lib.types.listOf lib.types.str;
    default = [
      "android-latest-release"
    ];
    example = [
      "android-latest-release"
      "android-15.0.0_r1"
    ];
  };

  config = {
    environment.etc."branches".text = lib.concatStringsSep "\n" cfg.branches;

    environment.systemPackages = [
      pkgs.dialog
      select-branch
    ];
  };
}
