# m920x — fixed personal device
#
# Lenovo ThinkCentre M920x Tiny
# Intel i5-8600 (6C/6T), 32GB DDR4, NVIDIA Tesla P4
# Role: local home server, can also be used as desktop with monitor
{
  lib,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../common/nixos-configuration.nix
    ../../../../modules/nixos/hyprland.nix
    ../../../../modules/nixos/comin.nix
    ../../../../modules/nixos/tpm-ssh.nix
  ];

  networking.hostName = "m920x";

  nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ];
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-server-lto;

  users.users.beacon.linger = true;
  home-manager.users.beacon.imports = [ ../../../../modules/home/tpm-ssh.nix ];
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-tpm-agent.sock";

  # ── Networking ──────────────────────────────────────────────
  # Use systemd-networkd with DHCP on wired NIC
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce false;
  systemd.network.enable = true;
  systemd.network.networks."10-eno1" = {
    matchConfig.Name = "eno1";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  # ── Firmware ────────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;

  # ── Sudo ────────────────────────────────────────────────────
  security.sudo.wheelNeedsPassword = lib.mkForce false;

  beacoworks.comin = {
    enable = true;
    machineId = "e4cda10da76f45fabf36296e65ff3ae9";
    remote = {
      url = "https://forgejo.beaco.works/infrastructure/infra.git";
      branch = "prod";
      username = "beacon1096";
    };
    tokenSecret.sopsFile = ../../../../secrets/shared/comin-forgejo-token.yaml;
  };

  # ── Sops ────────────────────────────────────────────────────
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # ── Firewall ────────────────────────────────────────────────
  networking.firewall.allowedTCPPorts = [ 22 ];
}
