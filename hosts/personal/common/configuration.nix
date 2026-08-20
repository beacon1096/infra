# Personal — shared system configuration for all Beacon's Macs
{ pkgs, config, ... }:

{
  imports = [
    ../../../modules/common
    ../../../modules/common/nix-mirror-cn.nix
    ../../../modules/darwin
  ];

  # Extra packages (base packages are in modules/common/packages.nix)
  # vscode and python3 are now in shared modules (modules/home/tools.nix and modules/common/packages.nix)
  environment.systemPackages = [ ];

  # Homebrew GUI apps
  homebrew.casks = [
    "parsec"
    "orbstack"
    "warp"
  ];

  # Touch ID & Apple Watch for sudo
  security.pam.services.sudo_local.touchIdAuth = true;
  security.pam.services.sudo_local.watchIdAuth = true;

  # Primary user
  system.primaryUser = "beacon";

  users.users.beacon = {
    name = "beacon";
    home = "/Users/beacon";
  };

  sops.secrets."personal/git/email" = {
    sopsFile = ../../../secrets/personal/git.yaml;
  };

  sops.templates."git-personal.inc" = {
    owner = "beacon";
    mode = "0400";
    content = ''
      [user]
          email = ${config.sops.placeholder."personal/git/email"}
    '';
  };

  environment.etc."git-personal.inc".source = config.sops.templates."git-personal.inc".path;
}
