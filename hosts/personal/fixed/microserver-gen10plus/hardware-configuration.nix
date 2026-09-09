# hpe-microserver — hardware-specific config
#
# HPE ProLiant MicroServer Gen10 Plus
# Intel CC150 @ 3.50GHz (8C/16T), 64GB DDR4 ECC
# 3× KIOXIA EXCERIA SATA SSD (mdadm RAID5)
# Intel I350 quad-port GbE, Matrox G200eH3 (iLO), HPE iLO5
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "ehci_pci" "usb_storage" "sd_mod" ];
  # Stage-1 only auto-loads boot.initrd.kernelModules. Without the mdraid
  # modules the RAID5 volume never assembles, so the btrfs root UUID does not
  # appear during boot.
  boot.initrd.kernelModules = [ "ahci" "sd_mod" "md_mod" "raid456" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = ''
    ARRAY /dev/md/data metadata=1.2 UUID=e9d3954f:671510b0:58c5efd5:0da767ef
  '';

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
