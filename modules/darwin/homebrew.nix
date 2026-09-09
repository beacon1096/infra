# Homebrew — declarative management via nix-darwin
#
# This sets the activation strategy. Specific brews/casks are
# added in each host's configuration.nix.
#
# NOTE: Homebrew must be installed before darwin-rebuild.
# The setup script handles this during bootstrap.
{ ... }:

{
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };
    taps = [ ];
    brews = [ ];
    casks = [ ];
    masApps = { };
  };

  # Add Homebrew to PATH (and MANPATH, INFOPATH, etc.)
  # nix-darwin's homebrew module manages packages but does not set up PATH.
  programs.zsh.interactiveShellInit = ''
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  '';
}
