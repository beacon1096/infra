# Surface Book 3 — secondary / spare machine
#
# Intel 10th Gen + NVIDIA GTX 1650/1660 Ti (dGPU in detachable base)
# nixos-hardware provides: linux-surface kernel, touch, cameras
{ pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/nixos-configuration.nix
    ../../../modules/nixos/hyprland.nix
  ];

  networking.hostName = "surface-book-3";

  # ── Intel + NVIDIA (Optimus) ────────────────────────────────
  # The dGPU is in the detachable keyboard base.
  # Use Intel iGPU by default; NVIDIA for offload when needed.
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
  ];

  # NVIDIA — use open-source kernel module (Turing+ supported)
  # Uncomment and configure after testing on actual hardware:
  # hardware.nvidia = {
  #   modesetting.enable = true;
  #   open = true;
  #   prime = {
  #     offload.enable = true;
  #     intelBusId = "PCI:0:2:0";     # TODO: verify with `lspci`
  #     nvidiaBusId = "PCI:2:0:0";    # TODO: verify with `lspci`
  #   };
  # };
  # services.xserver.videoDrivers = [ "nvidia" ];

  # ── Power management ────────────────────────────────────────
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "lock";
  };

  # Decrypt sops secrets with age key derived from SSH host key
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
