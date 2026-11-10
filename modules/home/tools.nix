# CLI tools
{ lib, pkgs, ... }:

{
  programs.fzf = {
    enable = true;
  };
  programs.zoxide.enable = true;
  programs.bat.enable = true;
  programs.eza.enable = true;

  # Account configuration lives in infra-private.
  programs.aerc.enable = true;

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
    package =
      if lib.versionAtLeast pkgs.vscode.version "1.129.0" then
        pkgs.vscode.overrideAttrs (
          old:
          let
            resources = if pkgs.stdenv.hostPlatform.isDarwin then "Contents/Resources" else "resources";
            nodeModules =
              if pkgs.stdenv.hostPlatform.isDarwin then "node_modules.asar.unpacked" else "node_modules";
            oldRipgrep = "${resources}/app/node_modules/@vscode/ripgrep/bin/rg";
            ripgrepSystem = {
              aarch64-darwin = "darwin-arm64";
              x86_64-darwin = "darwin-x64";
              aarch64-linux = "linux-arm64";
              armv7l-linux = "linux-arm";
              x86_64-linux = "linux-x64";
            }.${pkgs.stdenv.hostPlatform.system};
          in
          {
            # Backport nixpkgs' ripgrep-universal/asar fixes, retaining Darwin's signed vendor binary.
            postPatch =
              if lib.hasInfix oldRipgrep (old.postPatch or "") then
                lib.replaceStrings
                  [
                    oldRipgrep
                    ''asar extract "$packed" "$unpacked"''
                    ''ln -rs "$unpacked" "$packed"''
                  ]
                  [
                    "${resources}/app/${nodeModules}/@vscode/ripgrep-universal/bin/${ripgrepSystem}/rg"
                    ''
                      asar extract "$packed" "$unpacked"
                      if [ -d "$packed.unpacked" ]; then
                        cp -a "$packed.unpacked/." "$unpacked/"
                      fi
                    ''
                    ''
                      ln -rs "$unpacked" "$packed"
                      rm -rf "resources/app/node_modules.asar.unpacked"
                      ln -rs "$unpacked" "resources/app/node_modules.asar.unpacked"
                    ''
                  ]
                  (old.postPatch or "")
              else
                old.postPatch or "";
          }
        )
      else
        pkgs.vscode;
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
