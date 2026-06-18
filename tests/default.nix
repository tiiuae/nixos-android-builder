# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  self,
  pkgs,
  customPackages,
  installerModules,
  desktopInstallerModules,
  imageModules,
  desktopModules,
  nixos,
  desktop,

  keylimeModule,
  keylimeAgentModule,
  keylimeAgentPackage,
  keylimePackage,
}:
let
  inherit (pkgs) lib;

  # Disable the keylime agent in tests that don't provide a registrar.
  # Without a registrar the agent crash-loops, which can delay boot.
  noKeylimeAgent = {
    nodes.machine =
      { ... }:
      {
        services.keylime-agent.enable = lib.mkForce false;
      };
  };

  # NixOS VM tests include a custom backdoor for test instrumentation.
  # The installer does as well, while running inside a test VM, but
  # the installed system it boots into does not by default. So we
  # swap out the image to install with one that's extended to include
  # the test instrumentation backdoor.
  nixosWithBackdoor = nixos.extendModules {
    modules = [
      (
        { modulesPath, ... }:
        {
          imports = [
            "${modulesPath}/testing/test-instrumentation.nix"
          ];
          config = {
            testing = {
              backdoor = true;
              initrdBackdoor = true;
            };
            nixosAndroidBuilder.unattended.enable = lib.mkForce false;
          };
        }
      )
    ];
  };
  payload = "${nixosWithBackdoor.config.system.build.image}/${nixosWithBackdoor.config.image.filePath}";

  # Same for the desktop image: add test backdoor so the test driver
  # can interact with the installed system after the installer finishes.
  desktopWithBackdoor = desktop.extendModules {
    modules = [
      (
        { modulesPath, ... }:
        {
          imports = [
            "${modulesPath}/testing/test-instrumentation.nix"
          ];
          config = {
            testing = {
              backdoor = true;
              initrdBackdoor = true;
            };
            # Tests use the backdoor, not real auth. Allow passwordless
            # login to pass the "locked out" assertion.
            users.allowNoPasswordLogin = lib.mkForce true;
          };
        }
      )
    ];
  };
  desktopPayload = "${desktopWithBackdoor.config.system.build.image}/${desktopWithBackdoor.config.image.filePath}";

  unitTests = import ./unit-tests.nix {
    inherit pkgs keylimePackage;
  };
in
{
  inherit (unitTests) policyTests;
  integration = pkgs.testers.runNixOSTest {
    imports = [
      ./integration.nix
      noKeylimeAgent
      {
        _module.args = {
          inherit customPackages;
          imageModules = imageModules;
        };
      }
    ];
  };
  installer = pkgs.testers.runNixOSTest {
    imports = [
      ./installer.nix
      {
        _module.args = {
          inherit payload;
          inherit installerModules;
          vmInstallerTarget = "/dev/vdb";
          vmStorageTarget = "/dev/vdc";
        };
      }
    ];
  };
  installerInteractive = pkgs.testers.runNixOSTest {
    imports = [
      ./installer-interactive.nix
      {
        _module.args = {
          inherit payload;
          inherit installerModules;
          vmInstallerTarget = "select";
          vmStorageTarget = "select";
        };
      }
    ];
  };

  keylime = pkgs.testers.runNixOSTest {
    imports = [
      ./keylime.nix
      {
        _module.args = {
          imageModules = imageModules;
          inherit
            customPackages
            keylimeModule
            keylimeAgentModule
            keylimeAgentPackage
            ;
        };
      }
    ];
  };

  keylime-auto-enroll = pkgs.testers.runNixOSTest {
    imports = [
      ./keylime-auto-enroll.nix
      {
        _module.args = {
          imageModules = imageModules;
          inherit
            customPackages
            keylimeModule
            keylimeAgentModule
            keylimeAgentPackage
            ;
        };
      }
    ];
  };

  keylime-git-server = pkgs.testers.runNixOSTest {
    imports = [
      ./keylime-git-server.nix
      {
        _module.args = {
          imageModules = imageModules;
          inherit
            customPackages
            keylimeModule
            keylimeAgentModule
            keylimeAgentPackage
            ;
        };
      }
    ];
  };

  credentialStorage = pkgs.testers.runNixOSTest {
    imports = [
      ./credential-storage.nix
    ];
  };

  desktop = pkgs.testers.runNixOSTest {
    imports = [
      ./desktop.nix
      {
        _module.args = {
          inherit self customPackages;
          desktopModules = desktopModules;
        };
      }
    ];
  };

  desktopInstaller = pkgs.testers.runNixOSTest {
    imports = [
      ./desktop-installer.nix
      {
        _module.args = {
          inherit desktopInstallerModules;
          payload = desktopPayload;
          vmInstallerTarget = "/dev/vdb";
        };
      }
    ];
  };

}
