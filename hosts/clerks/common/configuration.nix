# Clerk common — shared system configuration for all AI clerk VMs
{ pkgs, ... }:

{
  imports = [
    ../../../modules/common
    ../../../modules/common/nix-mirror-cn.nix
    ../../../modules/darwin
  ];

  # Clerk-specific packages (base packages are in modules/common/packages.nix)
  environment.systemPackages = with pkgs; [
    python3
    nodejs
    ffmpeg
  ];

  # Homebrew
  homebrew = {
    brews = [
      "openclaw-cli"
    ];
    casks = [
      "parsec"
      "openclaw"
    ];
  };

  # All clerk VMs share the openclaw user
  system.primaryUser = "openclaw";

  users.users.openclaw = {
    name = "openclaw";
    home = "/Users/openclaw";
  };
}
