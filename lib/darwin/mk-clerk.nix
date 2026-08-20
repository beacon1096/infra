# mkClerk — factory function for AI clerk darwinConfigurations
#
# Usage in flake.nix:
#   mkClerk = import ./lib/darwin/mk-clerk.nix { inherit inputs nurOverlay; };
#   darwinConfigurations."clerk-alice" = mkClerk "alice";
#
# Each clerk gets:
#   - Shared system config from hosts/clerks/common/configuration.nix
#   - Shared home config from hosts/clerks/common/home.nix
#   - Per-clerk overrides from hosts/clerks/<name>/{configuration,home}.nix
#
# To add a new clerk:
#   1. Copy hosts/clerks/example/ to hosts/clerks/<name>/
#   2. Edit configuration.nix and home.nix as needed
#   3. Add to flake.nix: darwinConfigurations."clerk-<name>" = mkClerk "<name>";

{ inputs, nurOverlay, domainVars }:

name:

let
  inherit (inputs) nix-darwin home-manager sops-nix nix-openclaw;
in
nix-darwin.lib.darwinSystem {
  system = "aarch64-darwin";
  specialArgs = { inherit inputs nix-openclaw; } // domainVars;
  modules = [
    nurOverlay
    sops-nix.darwinModules.sops
    nix-openclaw.darwinModules.openclaw
    (../../hosts/clerks + "/${name}/configuration.nix")
    home-manager.darwinModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { inherit inputs nix-openclaw; } // domainVars;
      home-manager.users.openclaw = { ... }: {
        imports = [
          ../../hosts/clerks/common/home.nix
          (../../hosts/clerks + "/${name}/home.nix")
        ];
      };
    }
  ];
}
