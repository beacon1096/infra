{ pkgs, lib, ... }:

{
  # Desktop tools shared across Wayland compositors (Hyprland, niri, etc.)
  home.packages = with pkgs; [
    google-chrome
  ];
}
