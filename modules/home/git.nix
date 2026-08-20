# Git — base configuration (no signing or personal settings)
{ ... }:

{
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "code --wait";
    };
  };
}
