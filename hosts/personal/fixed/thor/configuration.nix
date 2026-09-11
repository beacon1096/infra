{ lib, pkgs, ... }:

let
  authorizedKeys = [
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
  ];
in
{
  imports = [ ./hardware-configuration.nix ];

  networking.hostName = "thor";
  networking.networkmanager.enable = true;
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
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    openssh.authorizedKeys.keys = authorizedKeys;
  };
  users.groups.debug = { };
  security.sudo.wheelNeedsPassword = false;

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
