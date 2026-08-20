# Shell — zsh + starship prompt
{ ... }:

{
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "eza -la --icons --git";
      ls = "eza --icons";
      lt = "eza --tree --icons --level=2";
      cat = "bat";
      # Don't alias `cd` to `z` — programs.zoxide.enable already installs a
      # `cd` shell function that wraps z and handles `cd -` / `cd ~` / no-arg
      # `cd` correctly. A static alias shadows that function and makes
      # zoxide's doctor warn on stderr, breaking tools that parse stdout.
      ".." = "cd ..";
      "..." = "cd ../..";
      # Platform-specific rebuild alias is set in:
      #   - hosts/personal/common/home.nix (darwin)
      #   - hosts/personal/common/nixos-home.nix (NixOS)
    };
    envExtra = ''
      if [ -r /run/secrets/rendered/opencode-web.env ]; then
        set -a
        source /run/secrets/rendered/opencode-web.env
        set +a
      fi
    '';
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = true;
      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[x](bold red)";
      };
    };
  };
}
