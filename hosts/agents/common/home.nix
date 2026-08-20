# Shared Home Manager base for headless coding agents.
{ lib, ... }:

{
  imports = [
    ../../../modules/home/profiles/coding-agent.nix
  ];

  home.username = lib.mkDefault "coder";
  home.homeDirectory = lib.mkDefault "/home/coder";
  home.stateVersion = "25.11";
}
