{ config, lib, ... }:

{
  imports = [
    ./shell.nix
    ./tools.nix
    ./desktop-tools.nix
    ./git.nix
    ./coding.nix
    ./chrome.nix
    ./firefox.nix
    ./communication.nix
    ./remote-desktop.nix
  ];

  # Strict mode for selected managed targets:
  # if these paths exist as regular files/dirs, remove them before link checks
  # so Home Manager can enforce declarative ownership.
  home.activation.strictManagedTargets = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    if [ -e "${config.home.homeDirectory}/.config/Code/User/settings.json" ] && [ ! -L "${config.home.homeDirectory}/.config/Code/User/settings.json" ]; then
      rm -f "${config.home.homeDirectory}/.config/Code/User/settings.json"
    fi
    if [ -e "${config.home.homeDirectory}/.config/fcitx5" ] && [ ! -L "${config.home.homeDirectory}/.config/fcitx5" ]; then
      rm -rf "${config.home.homeDirectory}/.config/fcitx5"
    fi
  '';

  home.stateVersion = "25.11";
}
