# m920x — fixed personal device
#
# Lenovo ThinkCentre M920x Tiny
# Intel i5-8600 (6C/6T), 32GB DDR4, NVIDIA Tesla P4
# Role: local home server, can also be used as desktop with monitor
{
  config,
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
  networking.interfaces.eno1.mtu = 9000;
  systemd.network.enable = true;
  systemd.network.networks."10-eno1" = {
    matchConfig.Name = "eno1";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.firewall.checkReversePath = "loose";

  beacoworks.sing-box = {
    enableDashboardUi = false;
    # Keep 100.64.0.0/10 on the TUN so userspace Tailscale remains the
    # out-of-band management path while m920x acts as the rack gateway.
    routeExcludeAddress = [
      "0.0.0.0/8"
      "10.0.0.0/8"
      "127.0.0.0/8"
      "169.254.0.0/16"
      "172.16.0.0/12"
      "192.168.0.0/16"
    ];
  };

  sops.secrets."bird/ospf-password" = {
    key = "password";
    sopsFile = ../../../../secrets/shared/ms-r1-ospf.yaml;
    restartUnits = [ "bird.service" ];
  };
  sops.templates."bird-ospf-password.conf" = {
    owner = "bird";
    group = "bird";
    mode = "0400";
    content = ''
      password "${config.sops.placeholder."bird/ospf-password"}" {
        id 1;
        algorithm keyed md5;
      };
    '';
  };

  beacoworks.ospf-egress = {
    enable = true;
    routerId = "172.16.100.250";
    installRoutesInKernel = false;
    staticRouteIncludeFiles = [
      "${inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.nchnroutes}/etc/bird/nchnroutes4.conf"
    ];
    ospfInterfaces = [
      {
        name = "eno1";
        type = "broadcast";
        authentication = "cryptographic";
        passwordSnippetFile = config.sops.templates."bird-ospf-password.conf".path;
      }
    ];
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
  networking.firewall = {
    allowedTCPPorts = [ 22 ];
    interfaces.eno1.allowedTCPPorts = [ 7890 ];
    extraCommands = ''
      # Covers Harvester management VLAN 100 and the Talos-i VLAN 107.
      iptables -w -A nixos-fw -i eno1 -s 172.16.96.0/20 -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept
      iptables -w -A nixos-fw -p 89 -j nixos-fw-accept
    '';
    extraStopCommands = ''
      iptables -w -D nixos-fw -i eno1 -s 172.16.96.0/20 -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept 2>/dev/null || true
      iptables -w -D nixos-fw -p 89 -j nixos-fw-accept 2>/dev/null || true
    '';
  };
}
