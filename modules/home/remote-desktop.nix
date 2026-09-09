{ pkgs, lib, ... }:

{
  home.packages = lib.optionals pkgs.stdenv.isLinux (with pkgs; [
    remmina
    parsec-bin
  ]);
}
