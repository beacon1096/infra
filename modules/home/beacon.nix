# Personal — Beacon's shared Home Manager settings (across all platforms)
{ pkgs, ... }:

{
  # GPG
  programs.gpg.enable = true;

  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    enableExtraSocket = true;
    defaultCacheTtl = 600;
    maxCacheTtl = 7200;
    # Unified pinentry based on platform
    pinentry.package = if pkgs.stdenv.isDarwin then pkgs.pinentry_mac else pkgs.pinentry-gnome3;
  };

  # YubiKey SSH keygrip (Authentication subkey [A])
  home.file.".gnupg/sshcontrol".text = ''
    25803EA9F190B4BECD18CA1BB2BAD205E957C2EB
  '';

  # Git — personal signing settings
  programs.git = {
    settings.user = {
      name = "Beacon Zhang";
    };
    settings.include.path = "/etc/git-personal.inc";
    signing = {
      key = "58FCE01334F49CA9";
      signByDefault = true;
    };
  };

  # Personal environment variables
  programs.zsh.initContent = ''
    export EDITOR="code --wait"
  '';
}
