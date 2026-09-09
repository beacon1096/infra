# darwin-only modules
{ ... }:

{
  imports = [
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
}
