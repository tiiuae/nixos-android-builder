# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  pkgs,
  config,
  ...
}:
{

  options.nixosAndroidBuilder.build = {
    repoManifestUrl = lib.mkOption {
      description = ''
        URL of a `repo` manifest to fetch sources from.
        Can be overriden at run-time by passing `--repo-manifest-url` to `fetch-android`.
      '';
      type = lib.types.str;
      default = "https://android.googlesource.com/platform/manifest";
    };
    lunchTarget = lib.mkOption {
      description = ''
        Name of lunch target to build.
        Can be overriden at run-time by passing `--lunch-target` to `build-android`.
      '';
      type = lib.types.str;
      default = "aosp_cf_x86_64_only_phone-aosp_current-eng";
    };
    userName = lib.mkOption {
      description = ''
        User name used for `repo`/`git` operations.
        Can be overriden at run-time by passing `--user-name` to `fetch-android`.
      '';
      type = lib.types.str;
      default = "CI User";
    };
    userEmail = lib.mkOption {
      description = ''
        Email address used for `repo`/`git` operations.
        Can be overriden at run-time by passing `--user-email` to `fetch-android`.
      '';
      type = lib.types.str;
      default = "ci@example.com";
    };
    sourceDir = lib.mkOption {
      description = ''
        Directory where `repo` checkout is stored.
        Can be overriden at run-time by passing `--source-dir` to `fetch-android` and `build-android`.
      '';
      type = lib.types.path;
      default = "/var/lib/build/source";
    };

  };

  config =
    let

      cfg = config.nixosAndroidBuilder.build;
      defaultBranch = builtins.head cfg.branches;

      # pkgs.writeShellScriptBin with bashInteractive instead of pkgsruntimeShell, so that we
      # don't get errors about the missing "complete" builtin.
      writeShellScriptBin =
        name: text:
        pkgs.writeTextFile {
          inherit name;
          executable = true;
          destination = "/bin/${name}";
          text = ''
            #!/bin/bash
            ${text}
          '';
          checkPhase = ''
            ${pkgs.stdenv.shellDryRun} "$target"
          '';
          meta.mainProgram = name;
        };

      fetchAndroid = writeShellScriptBin "fetch-android" ''
          set -e

        USER_EMAIL='${cfg.userEmail}'
        USER_NAME='${cfg.userName}'
        REPO_MANIFEST_URL='${cfg.repoManifestUrl}'
        SOURCE_DIR='${cfg.sourceDir}'

        if [ -f /tmp/selected-branch ]; then
          REPO_BRANCH="$(cat /tmp/selected-branch)"
        else
          REPO_BRANCH='${defaultBranch}'
        fi

        usage() {
          cat <<EOF
        Usage: $0 [options] [-- ...repo sync args...]

        Options:
          --user-email=EMAIL        Git user.email (default: ${cfg.userEmail})
          --user-name=NAME          Git user.name (default: ${cfg.userName})
          --repo-branch=BRANCH      Repo branch to init (default: ${defaultBranch}, or /tmp/selected-branch if present)
          --repo-manifest-url=URL   Repo manifest URL (default: ${cfg.repoManifestUrl})
          --source-dir=DIR          Source directory (default: ${cfg.sourceDir})
          -h, --help                Show this help message
        EOF
          exit 0
        }

        while [[ $# -gt 0 ]]; do
          case "$1" in
            -h|--help) usage ;;
            --user-email=*) USER_EMAIL="''${1#*=}" ;;
            --user-name=*) USER_NAME="''${1#*=}" ;;
            --repo-branch=*) REPO_BRANCH="''${1#*=}" ;;
            --repo-manifest-url=*) REPO_MANIFEST_URL="''${1#*=}" ;;
            --source-dir=*) SOURCE_DIR="''${1#*=}" ;;
            --) shift; break ;;
            *) break ;;
          esac
          shift
        done

        echo "Fetching android:"
        echo "  repo.branch      = $REPO_BRANCH"
        echo "  repo.manifestUrl = $REPO_MANIFEST_URL"
        echo

        mkdir -p "$SOURCE_DIR"
        cd "$SOURCE_DIR"

        git config --global color.ui true
        git config --global user.email "$USER_EMAIL"
        git config --global user.name "$USER_NAME"

        repo init \
          --partial-clone \
          --no-use-superproject \
          -b "$REPO_BRANCH" \
          -u "$REPO_MANIFEST_URL"

        repo sync -c "$@" || true
        repo sync -c "$@"
      '';

      buildAndroid = writeShellScriptBin "build-android" ''
        set -e

        SOURCE_DIR='${cfg.sourceDir}'
        LUNCH_TARGET='${cfg.lunchTarget}'

        usage() {
          cat <<EOF
        Usage: $0 [options] [-- ...m args...]

        Options:
          --source-dir=DIR      Source directory (default: ${cfg.sourceDir})
          --lunch-target=VALUE  Lunch target (default: ${cfg.lunchTarget})
          -h, --help            Show this help message
        EOF
          exit 0
        }

        while [[ $# -gt 0 ]]; do
          case "$1" in
            -h|--help) usage ;;
            --source-dir=*) SOURCE_DIR="''${1#*=}" ;;
            --lunch-target=*) LUNCH_TARGET="''${1#*=}" ;;
            --) shift; break ;;
            *) break ;;
          esac
          shift
        done

        echo "Building android:"
        echo "  lunch.target = $LUNCH_TARGET"
        echo "  make.args    = $@"
        echo

        cd "$SOURCE_DIR"
        source build/envsetup.sh || true
        lunch "$LUNCH_TARGET"
        m "$@"
      '';

      sbomAndroid = writeShellScriptBin "android-sbom" ''
          set -e

        ${buildAndroid}/bin/build-android sbom "$@"
      '';

      measureAndroidSource = writeShellScriptBin "android-measure-source" ''
        set -e

        SOURCE_DIR='${cfg.sourceDir}'

        usage() {
          cat <<EOF
        Usage: $0 [options] [-- ...m args...]

        Output a hash over a list of root hashes from all git repositories in the checkout,
        print them to stdout and write them to \$SOURCE_DIR/out/source_measurement.txt

        Options:
          --source-dir=DIR      Source directory (default: ${cfg.sourceDir})
          -h, --help            Show this help message
        EOF
          exit 0
        }

        while [[ $# -gt 0 ]]; do
          case "$1" in
            -h|--help) usage ;;
            --source-dir=*) SOURCE_DIR="''${1#*=}" ;;
            *) break ;;
          esac
          shift
        done

        cd $SOURCE_DIR
        mkdir -p out/

        repo forall -c '
          git ls-files | while read file
          do
            echo "$(sha256sum "$file")"
          done
        ' | sort | sha256sum | tee out/source_measurement.txt
      '';

    in
    {
      environment.variables = {
        "SOURCE_DIR" = cfg.sourceDir;
      };
      environment.systemPackages = [
        fetchAndroid
        buildAndroid
        sbomAndroid
        measureAndroidSource
      ];
      nixosAndroidBuilder.fhsEnv.packages = with pkgs; [
        # We just override a two deps of git-repo to include less features, but don't pull huge dependencies
        # into the closure.
        (git-repo.override {
          git = gitMinimal;
        })
        gitMinimal
        diffutils
        findutils
        curl
        binutils
        zip
        unzip
        zlib
        rsync
        libxml2
        libxslt
        fontconfig
        flex
        bison
        libX11
        mesa
        openssl
        jdk
        gnumake
        python3
      ];
    };
}
