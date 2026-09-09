# NixOS-only modules — shared across all NixOS hosts
{ pkgs, ... }:

{
  imports = [
    ./network.nix
    ./audio.nix
    ./bluetooth.nix
    ./security.nix
    ./paseo.nix
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

  # Enable zsh system-wide (matches darwin)
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

}
