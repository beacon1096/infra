# m920x — hardware-specific config
#
# Lenovo ThinkCentre M920x Tiny
# Intel i5-8600 (6C/6T), 32GB DDR4, KIOXIA EXCERIA G2 1TB NVMe
# NVIDIA Tesla P4, Intel I219-LM, Intel AX200 Wi-Fi
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" "crc32c-cryptoapi" ];
  boot.kernelModules = [ "kvm-intel" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
