{ pkgs, lib, inputs, ... }:

let
  unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  strata = inputs.beacon-nur-packages.packages.${pkgs.stdenv.hostPlatform.system}.strata.override {
    inherit (unstable) rustc cargo;
  };
in
{
  # Desktop tools shared across Wayland compositors (Hyprland, niri, etc.)
  home.packages = lib.optionals pkgs.stdenv.isLinux (with pkgs; [
    # Screenshot
    grim
    grimblast
    slurp
    swappy
    wl-clipboard

    # Brightness / media
    brightnessctl
    playerctl

    # File manager
    strata
    yazi

    # Audio control GUI
    pavucontrol

    # Bluetooth GUI
    blueman

    # Network manager GUI
    networkmanagerapplet
  ]);

  xdg.configFile."swappy/config" = lib.mkIf pkgs.stdenv.isLinux {
    text = ''
      [Default]
      save_dir=$HOME/Pictures/Screenshots
      save_filename_format=screenshot-%Y%m%d-%H%M%S.png
      early_exit=true
      auto_save=false
    '';
  };
}
