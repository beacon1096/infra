{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../../../modules/common/nix.nix
    ../../../../modules/common/sing-box.nix
    ../../../../modules/nixos/ospf-egress.nix
    ../../../../modules/nixos/sing-box.nix
  ];

  _module.args.k8sTransparentProxy = false;

  networking.hostName = "ms-r1";

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot = {
    enable = true;
    editor = false;
    configurationLimit = 10;
  };
  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot";
  };
  boot.supportedFilesystems = [
    "btrfs"
    "vfat"
  ];

  hardware.enableRedistributableFirmware = true;
  powerManagement.cpuFreqGovernor = "schedutil";
  services.irqbalance.enable = true;

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Transparent TUN replies are intentionally asymmetric and carry sing-box's
  # output mark, so strict reverse-path filtering drops valid forwarded traffic.
  networking.firewall.checkReversePath = "loose";

  networking.useDHCP = lib.mkForce false;
  networking.networkmanager.enable = lib.mkForce false;
  systemd.network.enable = true;
  systemd.network.wait-online.anyInterface = true;
  services.resolved.enable = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server";
    extraSetFlags = [
      "--accept-dns=false"
      "--accept-routes=false"
      "--advertise-exit-node"
      "--advertise-routes=172.16.80.0/20"
    ];
  };

  beacoworks.sing-box = {
    dnsListenAddress = "172.16.80.240";
    enableDashboardUi = false;
    enableTailscaleRouting = false;
    routeExcludeAddress = [
      "0.0.0.0/8"
      "10.0.0.0/8"
      "100.64.0.0/10"
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
    routerId = "172.16.80.240";
    installRoutesInKernel = false;
    trustedInterfaces = [ "tailscale0" ];
    staticRouteIncludeFiles = [
      "${inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.nchnroutes}/etc/bird/nchnroutes4.conf"
    ];
    ospfInterfaces = [
      {
        name = "enp49s0";
        type = "broadcast";
        txLength = 1500;
        authentication = "cryptographic";
        passwordSnippetFile = config.sops.templates."bird-ospf-password.conf".path;
      }
    ];
  };

  systemd.network.networks."10-enp49s0" = {
    matchConfig.Name = "enp49s0";
    networkConfig.DHCP = "yes";
    linkConfig = {
      RequiredForOnline = "routable";
      MTUBytes = "9216";
    };
  };

  systemd.network.networks."20-enp1s0" = {
    matchConfig.Name = "enp1s0";
    networkConfig.DHCP = "yes";
  };

  systemd.services.disable-rtl8127-eee = {
    description = "Disable Energy Efficient Ethernet on RTL8127 ports";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "sys-subsystem-net-devices-enp49s0.device"
      "sys-subsystem-net-devices-enp1s0.device"
      "network-online.target"
    ];
    path = [ pkgs.ethtool ];
    serviceConfig.Type = "oneshot";
    script = ''
      for dev in enp49s0 enp1s0; do
        [ -e "/sys/class/net/$dev" ] || continue
        ethtool --set-eee "$dev" eee off || true
      done
    '';
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      KbdInteractiveAuthentication = false;
      LogLevel = "VERBOSE";
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    interfaces.enp49s0 = {
      allowedTCPPorts = [
        53
        7890
      ];
      allowedUDPPorts = [ 53 ];
    };
    extraCommands = ''
      iptables -w -A nixos-fw -i enp49s0 -s 172.16.80.0/20 -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept
      iptables -w -A nixos-fw -p 89 -j nixos-fw-accept
    '';
    extraStopCommands = ''
      iptables -w -D nixos-fw -i enp49s0 -s 172.16.80.0/20 -p tcp -m conntrack --ctstate DNAT -j nixos-fw-accept 2>/dev/null || true
      iptables -w -D nixos-fw -p 89 -j nixos-fw-accept 2>/dev/null || true
    '';
  };

  users.mutableUsers = false;
  users.users.beacon = {
    isNormalUser = true;
    description = "Beacon Zhang";
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$tN01Y0uoc31ThXBq$hGi3IKw1aHC17Qz9VQUIsurSNb2lMjCxUt6AtxIiqgpomYYDVnMWiCsuPd0tEZvgsFZWqhz1cMTUvYb6AJCSu.";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHu3LcgN91fDQjnd6rlZj+wJSoB5MPOWBoLh176bzu8yO5sQCpAJ8MtUVZbE35LJvxwtDMl1blodBpeskXasOR0= beacon@surface-pro-8"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOsCCVuM5tqk6gfn9j7qDeaaN36ZY18Z8Q9ARViMSywNc5HD5ujV3ctD9x71q/yEC6M5liIheUOkILOzJ5E0Gdo= beacon@thinkbook-plus-hybrid"
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

  security.sudo = {
    wheelNeedsPassword = false;
    extraConfig = ''
      Defaults env_keep += "SSH_AUTH_SOCK"
    '';
  };

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  environment.systemPackages = with pkgs; [
    bat
    bird2
    curl
    dig
    ethtool
    fd
    git
    htop
    iperf3
    jq
    lsof
    neovim
    nftables
    pciutils
    ripgrep
    tcpdump
    tmux
    tree
    usbutils
    vim
    wget
  ];

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  system.stateVersion = "26.05";
}
