# Base system packages — installed on all machines
{ pkgs, lib, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
    neovim
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
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    pinentry_mac
  ];

  # Fonts — system-wide (needed by both Hyprland and macOS)
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];
}
