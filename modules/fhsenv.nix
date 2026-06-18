# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  pkgs,
  config,
  ...
}:
let
  # The default glibc build shipping with NixOS includes a dynamic linker (ld.so) that works
  # for NixOS, but ignores conventional FHS directories, such as /lib, by design.
  glibc = pkgs.callPackage ../packages/glibc-vanilla { };
  bash = pkgs.bash.override {
    interactive = true;
    forFHSEnv = true;
  };

  cfg = config.nixosAndroidBuilder.fhsEnv;
  storePaths = "${pkgs.closureInfo { rootPaths = cfg.packages; }}/store-paths";
  pins = cfg.pins;
  fhsEnv = (pkgs.callPackage ../packages/fhsenv { }) { inherit pins storePaths; };
in
{
  options.nixosAndroidBuilder.fhsEnv = {
    pins = lib.mkOption {
      description = ''
        A sorted list of packages to add first, so that they "win" if there are collisions/conflicts
        during creation of the FHS env. Unresolved collisions will produce a warning in the build log.

      '';
      type = lib.types.listOf lib.types.package;
    };

    packages = lib.mkOption {
      description = ''
        Packages needed to build Android AOSP. This is mostly copied from AOSP documentation, but could
        probably be reduced further, as AOSP repos ship much of it in-tree (i.e. python3, jdk, etc)
      '';
      type = lib.types.listOf lib.types.package;
    };
  };

  config = {
    # Expose the built fhs env in `system.build`, primarily for debugging
    system.build.fhsEnv = fhsEnv;

    nixosAndroidBuilder.fhsEnv = {
      pins = [
        # We always want our custom builds to win
        glibc
        bash
        # These are dependencies of packages below, where multiple builds with different parameters
        # ended up in the build closure. So we pin known-good packages here.
        pkgs.binutils
        pkgs.libgcc
        pkgs.systemdMinimal
        pkgs.zstd.bin
        pkgs.getent
        pkgs.gmp
      ];
      packages = [
        # Our custom builds must be included here as well, so they end up in the closure.
        # The rest of the pins above a transitive dependencies, which are implicitly included here.
        bash
        glibc
      ];
    };

    # Include /bin in $PATH in all shells.
    environment.variables = {
      "PATH" = "$PATH:/bin";
    };

    # Bind mount /bin, /lib and /lib64 to our FHS paths during runtime.
    # The source paths live in /nix/store which is an overlay mount, so
    # we add an explicit dependency to ensure the store is available.
    fileSystems =
      let
        mkBindMount = p: {
          device = p;
          options = [ "bind" ];
          fsType = "none";
          depends = [ "/nix/store" ];
        };
      in
      {
        "/bin" = mkBindMount "${fhsEnv}/bin";
        "/lib" = mkBindMount "${fhsEnv}/lib";
        "/lib64" = mkBindMount "${fhsEnv}/lib";
      };
  };
}
