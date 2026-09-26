{
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../../../modules/common/nix.nix
  ];

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

  # Forwarded traffic can use asymmetric paths on this router.
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
    ];
  };

  systemd.network.networks."10-enp49s0" = {
    matchConfig.Name = "enp49s0";
    networkConfig.DHCP = "yes";
    dhcpV4Config.UseDNS = false;
    dhcpV6Config.UseDNS = false;
    ipv6AcceptRAConfig.UseDNS = false;
    dns = [ "172.16.80.240" ];
    linkConfig = {
      RequiredForOnline = "routable";
      MTUBytes = "9216";
    };
  };

  systemd.network.networks."20-enp1s0" = {
    matchConfig.Name = "enp1s0";
    networkConfig.DHCP = "yes";
    dhcpV4Config.UseDNS = false;
    dhcpV6Config.UseDNS = false;
    ipv6AcceptRAConfig.UseDNS = false;
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
  };

  users.mutableUsers = false;
  users.users.beacon = {
    isNormalUser = true;
    description = "Beacon Zhang";
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
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

  users.groups.nixremote = { };
  users.users.nixremote = {
    isSystemUser = true;
    group = "nixremote";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhAOvxBZVK3hXZSYJqysAyq6cVTNV8KtZqJ2W+6UMzZ nix-builder@personal-fleet"
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
    "nixremote"
  ];
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  system.stateVersion = "26.05";
}
