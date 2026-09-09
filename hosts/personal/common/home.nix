# Personal — Beacon's Home Manager configuration
#
# GPG/SSH agent, YubiKey, git signing — only for beacon
{ pkgs, ... }:

{
  imports = [
    ../../../modules/home
    ../../../modules/home/beacon.nix
  ];

  # Darwin rebuild alias
  programs.zsh.shellAliases = {
    rebuild = "sudo darwin-rebuild switch --flake ~/.config/nix-darwin";
  };
}
