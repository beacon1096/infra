# Clerk "example" — template for new clerks
#
# To create a new clerk:
#   1. Copy this directory: cp -r hosts/clerks/example hosts/clerks/<name>
#   2. Edit configuration.nix and home.nix
#   3. Add to flake.nix:
#        darwinConfigurations."clerk-<name>" = mkClerk "<name>";
{ ... }:

{
  imports = [
    ../common/configuration.nix
  ];

  # Per-clerk system overrides go here
  # Example:
  # environment.systemPackages = with pkgs; [ ... ];
  # homebrew.casks = [ ... ];
}
