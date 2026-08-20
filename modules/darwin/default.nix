# darwin-only modules
{ config, ... }:

{
  imports = [
    ./sing-box.nix
    ./openssh.nix
    ./macos-defaults.nix
    ./homebrew.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";
  system.stateVersion = 6;

  nix.settings.trusted-users = [ "@admin" ];

  programs.zsh.enable = true;

  networking.knownNetworkServices = [
    "Ethernet"
    "Wi-Fi"
  ];
  networking.dns = [ "127.0.0.1" "::1" ];

  # sing-box: use sops-rendered config file
  # (the option is defined in ./sing-box.nix; the template in modules/common/sing-box.nix)
  services.sing-box.configFile = config.sops.templates."sing-box-config.json".path;
}
