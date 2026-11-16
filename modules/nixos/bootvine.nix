{ config, inputs, lib, ... }:

{
  imports = [ inputs.bootvine.nixosModules.default ];

  options.beacoworks.bootvine.enable = lib.mkEnableOption "the Bootvine boot screen";

  config = lib.mkIf config.beacoworks.bootvine.enable {
    boot.initrd.systemd.enable = true;
    boot.consoleLogLevel = lib.mkDefault 3;

    services.bootvine = {
      enable = true;
      settings.timing.keep-final-frame-for = lib.mkDefault "500ms";
    };
  };
}
