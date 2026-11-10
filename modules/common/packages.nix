# Base system packages — installed on all machines
{ config, pkgs, lib, ... }:

{
  options.beacoworks.packages.minimal = lib.mkEnableOption "a minimal package set for headless servers";

  config = {
    environment.systemPackages = with pkgs; [
      git
      curl
      wget
      ripgrep
      fd
      bat
      eza
      fzf
      jq
      tree
      htop
      tmux
      zoxide
      gnupg
      python3
      iperf3
    ] ++ lib.optionals (!config.beacoworks.packages.minimal) [
      vim
      neovim
    ] ++ lib.optionals config.beacoworks.packages.minimal [
      nano
    ] ++ lib.optionals pkgs.stdenv.isDarwin [
      pinentry_mac
    ];

    # Fonts — system-wide (needed by both Hyprland and macOS)
    fonts.packages = with pkgs; lib.optionals (!config.beacoworks.packages.minimal) [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      nerd-fonts.jetbrains-mono
    ];
  };
}
