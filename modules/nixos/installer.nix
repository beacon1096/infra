# NixOS Installer ISO — system-level configuration
#
# This module configures NixOS as a bootable installer ISO with:
#   - Chinese Nix mirrors for fast binary cache access
#   - Passwordless sudo for the nixos user
#   - SSH access with Beacon's keys
#   - GOPROXY set to goproxy.cn for nix-daemon FOD builds
#
# Build:
#   nix build .#installer-iso
#   # or for surface specifically:
#   nix build .#surface-installer-iso
{ lib
, pkgs
, modulesPath
, ...
}:

{
  imports = [
    # NixOS ISO image base
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    # Public installer dependencies only. Do not import modules/common here:
    # it wires machine-specific runtime secrets that an ephemeral ISO cannot
    # decrypt safely.
    ../../modules/common/nix.nix
    ../../modules/common/packages.nix
    ../../modules/common/nix-mirror-cn.nix
  ];

  # ── ISO image settings ──────────────────────────────────────
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";

  # ── Networking ───────────────────────────────────────────────
  networking.hostName = "nixos-installer";
  networking.networkmanager.enable = true;
  # Needed for networkmanager to work in ISO environment
  networking.wireless.enable = lib.mkForce false;

  # ── Users ────────────────────────────────────────────────────
  # nixos user: passwordless login for installer convenience
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    # No password set — the ISO base already sets initialHashedPassword = ""
  };
  security.sudo.wheelNeedsPassword = false;

  # root: SSH keys only, no password
  users.users.root = {
    openssh.authorizedKeys.keys = [
      # YubiKey authentication subkey
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
    ];
  };

  # ── SSH ──────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Build-time Go module mirror for nix-daemon FOD fetches ───
  # Sets GOPROXY so Go module fetches inside nix sandbox use goproxy.cn.
  # This is what worked on the Surface: GOPROXY=https://goproxy.cn nix build
  systemd.services.nix-daemon.environment = {
    GOPROXY = "https://goproxy.cn,direct";
  };

  # ── Console auto-login ───────────────────────────────────────
  services.getty.autologinUser = lib.mkForce "nixos";

  # ── System version ───────────────────────────────────────────
  system.stateVersion = "25.05";
}
