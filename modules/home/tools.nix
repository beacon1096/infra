# CLI tools
{ pkgs, ... }:

{
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

  # Visual Studio Code
  programs.vscode = {
    enable = true;
    profiles.default.extensions = with pkgs.vscode-extensions; [
      # anthropic.claude-code
      signageos.signageos-vscode-sops
    ];
    profiles.default.userSettings = {
      "update.mode" = "none";
      "claudeCode.preferredLocation" = "panel";
      "claudeCode.useTerminal" = false;
      "claudeCode.allowDangerouslySkipPermissions" = true;
    };
  };
}
