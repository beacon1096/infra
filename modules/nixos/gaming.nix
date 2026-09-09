# Gaming — Steam, Proton, Gamescope, GameMode
#
# This module is opt-in: import it only on gaming-capable hosts.
# It does NOT import Jovian-NixOS modules — those are added at the
# flake level for hosts that need Gaming Mode (e.g. MSI Claw).
{ config, lib, pkgs, ... }:

let
  cfg = config.beacon.gaming;
in
{
  options.beacon.gaming = {
    enableSteam = lib.mkEnableOption "Steam client and Proton support" // {
      default = true;
    };
  };

  config = {
    # GPU — enable hardware-accelerated graphics + 32-bit support
    hardware.graphics = {
      enable = true;
      enable32Bit = true;   # required by many games and Steam
    };

    # Steam
    programs.steam = lib.mkIf cfg.enableSteam {
      enable = true;
      # Proton-GE — community Proton build with extra game fixes
      extraCompatPackages = [ pkgs.proton-ge-bin ];
      # Open firewall for Steam Remote Play
      remotePlay.openFirewall = true;
    };

    # Gamescope — Valve's micro-compositor (used for Gaming Mode)
    programs.gamescope = {
      enable = true;
      capSysNice = true;
    };

    # GameMode — Feral's performance optimiser (nice, CPU governor, GPU clocks)
    programs.gamemode.enable = true;

    environment.systemPackages = with pkgs; [
      # lutris  # temporarily disabled — 32-bit openldap test failure in nixpkgs unstable
    ];

  };
}
