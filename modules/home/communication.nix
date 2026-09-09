{ pkgs, lib, inputs, ... }:

let
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    unstablePkgs.qq
    unstablePkgs.wechat-uos
    pkgs.telegram-desktop
  ];
}
