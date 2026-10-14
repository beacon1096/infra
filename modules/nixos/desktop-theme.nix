{ config, lib, ... }:

{
  programs.dconf.enable = lib.mkIf
    (lib.any (user: user.gtk.enable) (lib.attrValues (config.home-manager.users or { })))
    true;
}
