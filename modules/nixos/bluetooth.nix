# Bluetooth
{ ... }:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        # Allow modern BLE devices (controllers, audio)
        Experimental = true;
      };
    };
  };
}
