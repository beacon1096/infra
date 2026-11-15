{ inputs, lib, ... }:

{
  imports = [ inputs.bootvine.nixosModules.default ];

  boot.initrd.systemd.enable = true;
  boot.consoleLogLevel = lib.mkDefault 3;

  services.bootvine = {
    enable = true;
    settings.timing.keep-final-frame-for = lib.mkDefault "500ms";
  };
}
