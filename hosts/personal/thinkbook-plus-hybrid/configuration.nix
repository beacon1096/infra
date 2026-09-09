{ pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/nixos-configuration.nix
    ../../../modules/nixos/hyprland.nix
    ../../../modules/nixos/tpm-ssh.nix
  ];

  networking.hostName = "thinkbook-plus-hybrid";

  # The Hybrid Tab can leave the i915 eDP link stuck in PSR2 after returning from Android.
  boot.kernelParams = [ "i915.enable_psr=0" ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ intel-media-driver ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  services.fprintd.enable = true;
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  environment.systemPackages = with pkgs; [ wvkbd ];

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "lock";
  };

  home-manager.users.beacon.wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    "eDP-1, 2880x1800@60, 0x0, 1.5"
    ", preferred, auto, 1"
  ];

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="17ef", ATTR{idProduct}=="7ebf", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hybrid-display-resume.service"
  '';

  systemd.services.hybrid-display-resume = {
    description = "Restore the Hybrid Tab display after switching from Android";
    serviceConfig = {
      Type = "oneshot";
      User = "beacon";
      TimeoutStartSec = "20s";
    };
    path = [ pkgs.hyprland ];
    script = ''
      sleep 3
      test -d /run/user/1000/hypr || exit 0
      socketDir=$(find /run/user/1000/hypr -mindepth 1 -maxdepth 1 -type d -print -quit)
      test -n "$socketDir" || exit 0
      export XDG_RUNTIME_DIR=/run/user/1000
      export HYPRLAND_INSTANCE_SIGNATURE="''${socketDir##*/}"
      timeout 6s hyprctl dispatch dpms off eDP-1
      sleep 2
      timeout 6s hyprctl dispatch dpms on eDP-1
    '';
  };

  home-manager.users.beacon.imports = [ ../../../modules/home/tpm-ssh.nix ];
}
