{ inputs, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/nixos-configuration.nix
    ../../../modules/nixos/hyprland.nix
  ];

  networking.hostName = "thinkbook-plus-hybrid";

  # The Hybrid Tab can leave the i915 eDP link stuck in PSR2 after returning from Android.
  boot.kernelParams = [ "i915.enable_psr=0" ];
  beacoworks.remoteBuilder.sshKey = lib.mkDefault "/etc/ssh/ssh_host_ed25519_key";

  boot.kernelPatches = [
    {
      name = "thinkbook-plus-g5-hybrid-txnw2781";
      patch = pkgs.writeText "thinkbook-plus-g5-hybrid-txnw2781.patch" ''
        diff --git a/sound/hda/codecs/realtek/alc269.c b/sound/hda/codecs/realtek/alc269.c
        --- a/sound/hda/codecs/realtek/alc269.c
        +++ b/sound/hda/codecs/realtek/alc269.c
        @@ -7484 +7484 @@ static const struct hda_quirk alc269_fixup_tbl[] = {
        -	SND_PCI_QUIRK(0x17aa, 0x38fd, "ThinkBook plus Gen5 Hybrid", ALC287_FIXUP_TAS2781_I2C),
        +	SND_PCI_QUIRK(0x17aa, 0x38fd, "ThinkBook plus Gen5 Hybrid", ALC287_FIXUP_TXNW2781_I2C),
      '';
    }
  ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ intel-media-driver ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  programs.steam.enable = true;

  services.fprintd.enable = true;
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  environment.systemPackages = [
    (inputs.beacon-nur-packages.packages.${pkgs.system}.bakaxl-bunny.override {
      wrapGAppsHook = pkgs.wrapGAppsHook3;
    })
    pkgs.wvkbd
  ];

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "lock";
  };

  home-manager.users.beacon.wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    "eDP-1, 2880x1800@60, 0x0, 1.5"
    ", preferred, auto, 1"
  ];

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="04f3", ATTR{idProduct}=="42ea", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hybrid-display-resume.service"
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
}
