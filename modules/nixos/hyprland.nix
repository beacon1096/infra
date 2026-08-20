# Hyprland — system-level configuration
#
# This module is opt-in: import it on hosts that need a desktop environment.
# User-level Hyprland configuration lives in modules/home/hyprland.nix.
{ pkgs, lib, ... }:

{
  # Hyprland compositor
  programs.hyprland.enable = true;

  # Login manager — greetd with tuigreet
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd Hyprland";
      user = "greeter";
    };
  };

  # greetd's systemd unit defaults to NoNewPrivileges=true, which propagates
  # down the entire process tree (greetd → Hyprland → terminal).  This breaks
  # sudo inside desktop terminals.  Disable it so privilege elevation works.
  # systemd.services.greetd.serviceConfig.NoNewPrivileges = lib.mkForce false;

  # XDG portals — required for screen sharing, file dialogs, etc.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
  };

  # Thumbnail generation for file managers
  services.tumbler.enable = true;

  # GNOME Keyring — stores credentials for apps (e.g. browsers)
  services.gnome.gnome-keyring.enable = true;
}
