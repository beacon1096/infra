# NixOS-only modules — shared across all NixOS hosts
{ pkgs, ... }:

{
  imports = [
    ./network.nix
    ./audio.nix
    ./bluetooth.nix
    ./security.nix
    ./sing-box.nix
    ./paseo.nix
    ./ospf-egress.nix
    ./compat-binaries.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "ntfs" ];

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
  };

  # Console
  console.keyMap = "us";

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # System version
  system.stateVersion = "25.05";

  # Nix settings (supplement modules/common/nix.nix)
  # On NixOS, trusted-users uses @wheel instead of @admin
  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  # Nix daemon proxy — route build-time fetches through local sing-box
  # sing-box listens on 127.0.0.1:7890 (mixed HTTP/SOCKS5 inbound).
  # This ensures `nix build`, `nixos-rebuild`, FOD fetches (e.g. Go modules)
  # all go through the proxy without manual env vars.
  systemd.services.nix-daemon.environment = {
    http_proxy = "http://127.0.0.1:7890";
    https_proxy = "http://127.0.0.1:7890";
    all_proxy = "socks5://127.0.0.1:7890";
    # Keep LAN and tailnet services on their direct paths.
    no_proxy = "localhost,127.0.0.1,::1,10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16,.beaco.works,.beacoworks.xyz";
    NO_PROXY = "localhost,127.0.0.1,::1,10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16,.beaco.works,.beacoworks.xyz";
  };

  # Enable zsh system-wide (matches darwin)
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

}
