# Platform-neutral, headless profile for Coder-backed coding agents.
{ pkgs, ... }:

{
  imports = [
    ../shell.nix
    ../git.nix
    ../coding-agent.nix
  ];

  programs.fzf = {
    enable = true;
  };
  programs.zoxide.enable = true;
  programs.bat.enable = true;
  programs.eza.enable = true;

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    keyMode = "vi";
    baseIndex = 1;
    escapeTime = 0;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  home.packages = with pkgs; [
    curl
    jq
    ripgrep
    fd
    git
  ];
}
