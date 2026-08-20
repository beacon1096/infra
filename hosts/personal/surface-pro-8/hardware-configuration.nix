# Surface Pro 8 — hardware configuration (Identical to /etc/nixos-old/hardware-configuration.nix)
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Override disko-generated fileSystems with correct UUIDs for the new NVMe
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-uuid/ab5eed42-e612-4516-95ed-15dad9a75e50";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd" ];
  };
  fileSystems."/home" = lib.mkForce {
    device = "/dev/disk/by-uuid/ab5eed42-e612-4516-95ed-15dad9a75e50";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" ];
  };
  fileSystems."/nix" = lib.mkForce {
    device = "/dev/disk/by-uuid/ab5eed42-e612-4516-95ed-15dad9a75e50";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
  };
  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-uuid/82C0-3D3E";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
