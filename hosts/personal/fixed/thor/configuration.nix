{ lib, pkgs, ... }:

let
  authorizedKeys = [
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
  ];
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../../modules/nixos/hyprland.nix
  ];

  networking.hostName = "thor";
  networking.networkmanager.enable = true;
  networking.networkmanager.ethernet.macAddress = "permanent";
  networking.useDHCP = lib.mkDefault true;
  # Ethernet and Wi-Fi on the same subnet can receive replies over different interfaces.
  networking.firewall.checkReversePath = "loose";

  # Keep each interface's ARP replies local to avoid NetworkManager false duplicate detection.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.default.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
    "net.ipv4.conf.default.arp_announce" = 2;
  };

  services.tailscale.enable = true;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;
  users.mutableUsers = true;
  users.users.beacon = {
    isNormalUser = true;
    description = "Beacon Zhang";
    extraGroups = [ "networkmanager" "wheel" "video" "input" ];
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  users.groups.debug = { };
  security.sudo.wheelNeedsPassword = false;
  security.polkit.enable = true;
  security.rtkit.enable = true;
  security.pam.services.hyprlock = { };
  programs.firefox.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.beacon = {
      imports = [ ../../../../modules/home/hyprland.nix ];
      home.stateVersion = "26.05";
      home.packages = with pkgs; [
        brightnessctl
        grimblast
        networkmanagerapplet
        pavucontrol
        playerctl
        slurp
        swappy
        thunar
        wl-clipboard
      ];
      wayland.windowManager.hyprland.settings = {
        monitor = lib.mkForce [ ", preferred, auto, 1" ];
        "$fileManager" = lib.mkForce "thunar";
      };
    };
  };

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    efibootmgr
    ethtool
    git
    gptfdisk
    jq
    lvm2
    nvme-cli
    pciutils
    ripgrep
    tcpdump
    tmux
    usbutils
  ];

  zramSwap.enable = true;
  zramSwap.memoryPercent = 25;
  time.timeZone = "Asia/Shanghai";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "26.05";
}
