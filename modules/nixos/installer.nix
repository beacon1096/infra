# NixOS Installer ISO — system-level configuration
#
# This module configures NixOS as a bootable installer ISO with:
#   - sing-box proxy (pre-configured, decrypted via embedded age key)
#   - Chinese Nix mirrors for fast binary cache access
#   - Passwordless sudo for the nixos user
#   - SSH access with Beacon's keys
#   - GOPROXY set to goproxy.cn for nix-daemon FOD builds
#
# The age private key is embedded at build time from secrets/installer/age-key.yaml.
# This is acceptable since the ISO is for personal use and not publicly distributed.
#
# Build:
#   nix build .#installer-iso
#   # or for surface specifically:
#   nix build .#surface-installer-iso
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    # NixOS ISO image base
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    # Shared NixOS base (nix settings, packages, sing-box config, CN mirrors)
    ../../modules/common
    ../../modules/common/nix-mirror-cn.nix
    # sing-box NixOS systemd binding
    ./sing-box.nix
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

  # ── sops-nix: installer age key embedded at build time ───────
  #
  # The ISO has no persistent SSH host key (it's ephemeral), so we
  # cannot use ssh-to-age. Instead, we embed the installer age private
  # key directly — it's stored encrypted in secrets/installer/age-key.yaml
  # and decrypted at *build time* by the Mac Mini (which has the GPG key).
  #
  # At ISO runtime, sops-nix reads the embedded age key to decrypt secrets.
  sops.age.keyFile = "/etc/sops-installer-age-key";

  # Write the embedded age key to the ISO at activation time.
  # The key comes from the sops secret decrypted during build.
  sops.secrets."installer/age-private-key" = {
    sopsFile = ../../secrets/installer/age-key.yaml;
    # Write to a stable path that sops.age.keyFile points to
    path = "/etc/sops-installer-age-key";
    mode = "0400";
  };

  # ── Build-time proxy for nix-daemon FOD fetches ──────────────
  # Sets GOPROXY so Go module fetches inside nix sandbox use goproxy.cn.
  # This is what worked on the Surface: GOPROXY=https://goproxy.cn nix build
  systemd.services.nix-daemon.environment = {
    GOPROXY = "https://goproxy.cn,direct";
    http_proxy = "http://127.0.0.1:7890";
    https_proxy = "http://127.0.0.1:7890";
    HTTP_PROXY = "http://127.0.0.1:7890";
    HTTPS_PROXY = "http://127.0.0.1:7890";
    no_proxy = "localhost,127.0.0.1,::1,10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16,.beaco.works,.beacoworks.xyz";
    NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16,.beaco.works,.beacoworks.xyz";
  };

  # ── Console auto-login ───────────────────────────────────────
  services.getty.autologinUser = lib.mkForce "nixos";

  # ── System version ───────────────────────────────────────────
  system.stateVersion = "25.05";
}
