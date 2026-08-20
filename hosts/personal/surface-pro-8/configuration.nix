# Surface Pro 8 — portable workstation
#
# Intel 11th Gen + Iris Xe Graphics
# Primary use: on-the-go work, remote into company machines
# nixos-hardware provides: linux-surface kernel, IPTS touchscreen/pen, cameras
{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../common/nixos-configuration.nix
    ../../../modules/nixos/hyprland.nix
    ../../../modules/nixos/tpm-ssh.nix # TPM2 and SSH integration
    ../../../modules/nixos/tpm-sops.nix # age-plugin-tpm backed sops-nix
  ];

  networking.hostName = "surface-pro-8";

  # Let the root-owned nix-daemon reuse the user TPM-backed SSH agent for
  # remote builds to microserver-gen10plus.
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-tpm-agent.sock";

  # ── Kernel ──────────────────────────────────────────────────
  # linux-surface kernel (enabled via nixos-hardware in flake.nix)
  # Provides:
  #   - IPTS touchscreen/pen support
  #   - Surface cameras (IPU6)
  #   - Surface-specific battery / thermal optimizations
  # Note: Type Cover works with mainline kernel since ~5.x
  #
  # With Attic binary cache, the patched kernel is fetched pre-built
  # from CI instead of compiling locally.

  # ── Intel GPU ───────────────────────────────────────────────
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver # VA-API (iHD)
  ];
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # ── Touch / pen ─────────────────────────────────────────────
  # On-screen keyboard for tablet mode
  environment.systemPackages = with pkgs; [
    wvkbd # Wayland virtual keyboard
  ];

  # ── Power management ────────────────────────────────────────
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  # ── Virtualization ──────────────────────────────────────────
  virtualisation.vmware.host.enable = true;

  # Thermal guardrail for SP8:
  # cap Intel pstate max performance to reduce sustained heat/noise.
  # Tune this value (65-85) based on your workload and temperature target.
  systemd.tmpfiles.rules = [
    "w /sys/devices/system/cpu/intel_pstate/max_perf_pct - - - - 75"
  ];

  # Auto-suspend / screen lock on lid close
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "lock";
  };

  # Sops TPM integration lives in tpm-sops.nix and now expects an
  # age-plugin-tpm identity file at /var/lib/sops-nix/age-plugin-tpm.txt.

  # Keep TPM-backed SSH as the default, but allow explicit switching to the
  # gpg-agent/YubiKey SSH socket when needed.
  home-manager.users.beacon.imports = [ ../../../modules/home/tpm-ssh.nix ];
}
