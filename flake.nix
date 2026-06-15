{
  description = "An ephemeral NixOS system to build Android Open Source Project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-26.05";
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      system-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      customPackages = import ./packages { inherit pkgs; };
      inherit (customPackages)
        tpm2-tools
        keylime
        keylime-agent
        keylime-git-clone
        measuredBoot
        attestation-ctl
        secureBootScripts
        diskInstaller
        ;

      nixosModules = lib.pipe (builtins.readDir ./modules) [
        (lib.filterAttrs (n: v: (lib.hasSuffix ".nix" n) && v == "regular"))
        (lib.mapAttrs' (
          n: _v: {
            name = lib.removeSuffix ".nix" n;
            value = ./modules/${n};
          }
        ))
      ];

      builderModules = [
        ./modules/android-build-env.nix
        ./modules/artifact-storage.nix
        ./modules/base.nix
        ./modules/builder.nix
        ./modules/branch-selector.nix
        ./modules/credential-storage.nix
        ./modules/debug.nix
        ./modules/disable-ldso.nix
        ./modules/fatal-error.nix
        ./modules/fhsenv.nix
        ./modules/image.nix
        ./modules/keylime.nix
        ./modules/keylime-agent.nix
        ./modules/secure-boot.nix
        ./modules/unattended.nix
        ./modules/vm.nix
        ./modules/yubikey-auth.nix
        ./configuration.nix
      ];

      imageModules = [
        (
          { modulesPath, ... }:
          {
            imports = [
              "${modulesPath}/image/repart.nix"
              "${modulesPath}/profiles/minimal.nix"
              "${modulesPath}/profiles/perlless.nix"
              "${modulesPath}/virtualisation/qemu-vm.nix"
            ];
          }
        )
      ]
      ++ builderModules;

      nixos = pkgs.nixos {
        nixpkgs.hostPlatform = { inherit system; };
        imports = imageModules;
        _module.args = { inherit customPackages; };
      };
      run-vm = nixos.config.system.build.vmWithWritableDisk;
      image = nixos.config.system.build.image;

      mkInstallerModules = target: [
        diskInstaller.module
        diskInstaller.vm
        nixosModules.fatal-error
        {
          diskInstaller.payload = "${target.config.system.build.image}/${target.config.image.filePath}";
        }
      ];

      installerModules = mkInstallerModules nixos;

      installer = pkgs.nixos {
        nixpkgs.hostPlatform = { inherit system; };
        imports = installerModules;
        _module.args = { inherit customPackages; };
      };
      installer-vm = installer.config.system.build.vmWithInstallerDisk;
      installer-image = installer.config.system.build.image;

      desktopInstallerModules = mkInstallerModules desktop;

      desktop-installer = pkgs.nixos {
        nixpkgs.hostPlatform = { inherit system; };
        imports = desktopInstallerModules;
        _module.args = { inherit customPackages; };
      };
      desktop-installer-vm = desktop-installer.config.system.build.vmWithInstallerDisk;
      desktop-installer-image = desktop-installer.config.system.build.image;

      desktopModules = [
        ./modules/base.nix
        ./modules/debug.nix
        ./modules/fatal-error.nix
        ./modules/secure-boot.nix
        ./modules/yubikey-auth.nix
        ./modules/desktop.nix
        ./modules/desktop-image.nix
        ./modules/desktop-vm.nix
        ./desktop-configuration.nix
        (
          { modulesPath, ... }:
          {
            imports = [
              "${modulesPath}/image/repart.nix"
              "${modulesPath}/profiles/minimal.nix"
              "${modulesPath}/virtualisation/qemu-vm.nix"
            ];
          }
        )
      ];

      desktop = pkgs.nixos {
        nixpkgs.hostPlatform = { inherit system; };
        imports = desktopModules;
        _module.args = { inherit customPackages self; };
      };
      run-desktop-vm = desktop.config.system.build.vmWithWritableDisk;

      docs = pkgs.callPackage ./packages/docs {
        inherit self nixos;
      };

      bookDocs = pkgs.callPackage ./packages/docs/book.nix {
        inherit self nixos;
      };

    in
    {
      inherit nixosModules;
      nixosConfigurations = {
        inherit
          nixos
          installer
          desktop
          desktop-installer
          ;
      };

      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-tree;

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = with secureBootScripts; [
            attestation-ctl
            create-signing-keys
            diskInstaller.configure
            docs.build-docs
            docs.watch-docs
            pkgs.pam_u2f
          ];
        };
      };

      packages.${system} = {
        inherit
          run-vm
          run-desktop-vm
          image
          installer-image
          installer-vm
          desktop-installer-image
          desktop-installer-vm
          keylime
          keylime-agent
          keylime-git-clone
          ;
        inherit (secureBootScripts) create-signing-keys;
        inherit attestation-ctl;
        inherit (measuredBoot) measure-boot-state report-measured-boot-state debug-measured-boot-state;
        configure-disk-image = diskInstaller.configure;
        inherit (bookDocs)
          book-html
          build-book
          preview-book
          deploy-docs
          ;
        default = image;
      };

      systemConfigs.default = system-manager.lib.makeSystemConfig {
        modules = [
          ./system-manager/tpm2.nix
          ./system-manager/keylime.nix
          {
            nixpkgs.hostPlatform = system;
            services.keylime = {
              enable = true;
              registrar.enable = true;
              verifier.enable = true;
              autoEnroll.enable = true;
              gitServer = {
                enable = true;
                repos = [ "config" ];
              };
            };
          }
        ];
      };

      checks.${system} = import ./tests/default.nix {
        inherit
          self
          pkgs
          customPackages
          installerModules
          desktopInstallerModules
          imageModules
          desktopModules
          nixos
          desktop
          ;
        keylimeModule = nixosModules.keylime;
        keylimeAgentModule = nixosModules.keylime-agent;
        keylimeAgentPackage = keylime-agent;
        keylimePackage = keylime;
      };
    };
}
