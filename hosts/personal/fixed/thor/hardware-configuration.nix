{ config, lib, ... }:

{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  nixpkgs.config.allowUnfree = true;
  hardware.enableAllHardware = lib.mkForce false;
  hardware.graphics.enable = true;

  # UEFI must use Device Tree and Display Hand-Off Never for NVIDIA display takeover.
  hardware.nvidia-jetpack = {
    enable = true;
    som = "thor-agx";
    carrierBoard = "devkit";
    majorVersion = "7";
    configureCuda = false;
    maxClock = false;
    modesetting.enable = true;
    firmware = {
      autoUpdate = false;
      fskp.enable = false;
      # jetpack-nixos #543 evaluates this tag even with factory provisioning disabled.
      fskp.fuseBlob.insecureClearText = true;
    };
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;

  boot.extraModulePackages = [
    (config.boot.kernelPackages.callPackage ../../../../packages/r8127 { })
  ];
  boot.kernelModules = [ "r8127" ];
  boot.extraModprobeConfig = ''
    options nvidia-drm fbdev=1
  '';
  # Make the firmware TPM available before systemd waits 90 seconds for it in initrd.
  boot.initrd.availableKernelModules = [ "tpm_ftpm_tee" ];
  boot.zfs.forceImportRoot = false;
  boot.supportedFilesystems = lib.mkForce [ "ext4" "vfat" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/thor-root";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/THOR-EFI";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
}
