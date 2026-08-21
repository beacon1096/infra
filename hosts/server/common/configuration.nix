# Server common — shared NixOS system configuration for headless servers
#
# Intentionally does not import modules/nixos (desktop-only: audio, bluetooth,
# hyprland, NetworkManager) or modules/common/coding.nix (dev tooling).
# Service modules are imported but disabled by default — enable per-host.
{ inputs, pkgs, ... }:

{
  imports = [
    ../../../modules/common/nix.nix
    ../../../modules/common/remote-builder.nix
    ../../../modules/common/packages.nix
  ];

  # ── Boot ────────────────────────────────────────────────────
  # BIOS machines use GRUB; disko auto-registers the device from the EF02
  # partition — do NOT set boot.loader.grub.device here or it duplicates.
  boot.loader.grub.enable = true;
  nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ];
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-server-lto;

  # ── KVM virtio kernel modules ───────────────────────────────
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
    "virtio_scsi"
    "ahci"
    "sd_mod"
  ];

  # ── Locale / console ────────────────────────────────────────
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # ── SSH ─────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      KbdInteractiveAuthentication = false;
      LogLevel = "VERBOSE";
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  services.fail2ban = {
    enable = true;
    bantime = "1h";
    maxretry = 5;
    jails.sshd.settings = {
      enabled = true;
      backend = "systemd";
      findtime = "10m";
      bantime = "1h";
      maxretry = 5;
    };
  };

  # ── Docker ──────────────────────────────────────────────────
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  # ── Networking base ─────────────────────────────────────────
  # Each server configures its own static address via systemd-networkd.
  networking.useDHCP = false;
  # mDNS / Avahi not needed on headless servers
  services.avahi.enable = false;

  # Firewall
  networking.firewall = {
    enable = true;
  };

  # ── Users ───────────────────────────────────────────────────
  users.mutableUsers = false;

  users.users.beacon = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = [
      # YubiKey authentication subkey (GPG → SSH)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      # Active SSH key from Surface Pro 8
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHu3LcgN91fDQjnd6rlZj+wJSoB5MPOWBoLh176bzu8yO5sQCpAJ8MtUVZbE35LJvxwtDMl1blodBpeskXasOR0= beacon@surface-pro-8"
      # TPM-backed SSH key from MSI Claw
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
      # TPM-backed SSH key from ThinkBook Plus Hybrid
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOsCCVuM5tqk6gfn9j7qDeaaN36ZY18Z8Q9ARViMSywNc5HD5ujV3ctD9x71q/yEC6M5liIheUOkILOzJ5E0Gdo= beacon@thinkbook-plus-hybrid"
      # TPM-backed SSH key from m920x
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBC3fP4DxeRnXRpwehi0En0e2n/HpOsdF1hf33NfgbKzkWSBecjJlix5xldfSKk6t378lMJ4yMcQVrwvrLHQwYFg= beacon@m920x"
      # TPM-backed SSH key from microserver-gen10plus
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJGwIGaHwdhEQ8QvZhXoArtJ4I44fxsFoihasONWAIrBBJWlKcyfwWOTFPelUil0hfI/ENzTdgrtxcVIukqqstQ= beacon@microserver-gen10plus-tpm"
      # Trusted coding agent runtime
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDP4oDTGH/Pk+6BPAcxxAsLTxxYU7mIz1Qfv4RX1FH7 Agent @ Beacoworks"
    ];
  };

  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
    ];
  };

  # ── Shell ───────────────────────────────────────────────────
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  # ── Nix ─────────────────────────────────────────────────────
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  system.stateVersion = "25.11";
}
