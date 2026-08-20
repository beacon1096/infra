# Personal — Beacon's Home Manager configuration for NixOS hosts
#
# NixOS counterpart to home.nix (which has darwin-specific pinentry_mac).
# Imports the shared home modules + Hyprland user config.
{ pkgs, ... }:

{
  imports = [
    ../../../modules/home
    ../../../modules/home/hyprland.nix
    ../../../modules/home/beacon.nix
  ];

  # NixOS rebuild alias
  programs.zsh.shellAliases = {
    rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#$(hostname) && sudo attic-upload-system";
  };
}
