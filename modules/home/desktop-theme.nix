{ pkgs, ... }:

{
  gtk = {
    enable = true;
    colorScheme = "dark";
    gtk3.theme.name = "Adwaita-dark";
  };

  xdg.portal = {
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.hyprland = {
      default = [ "hyprland" "gtk" ];
      "org.freedesktop.impl.portal.Settings" = [ "gtk" ];
    };
  };
}
