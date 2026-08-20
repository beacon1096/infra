# Personal — Beacon's shared Home Manager settings (across all platforms)
{ pkgs, ... }:

{
  # GPG
  programs.gpg.enable = true;

  services.gpg-agent = {
    enable = true;
    # Don't let gpg-agent claim SSH_AUTH_SOCK globally — we want tpm-ssh-agent
    # as the default. The SSH socket is still available via `use-gpg-ssh-agent`.
    enableSshSupport = false;
    extraConfig = "enable-ssh-support";
    enableExtraSocket = true;
    defaultCacheTtl = 600;
    maxCacheTtl = 7200;
    # Unified pinentry based on platform
    pinentry.package = if pkgs.stdenv.isDarwin then pkgs.pinentry_mac else pkgs.pinentry-gnome3;
  };

  # Manually activate the gpg-agent SSH socket so `use-gpg-ssh-agent` works,
  # without letting enableSshSupport override SSH_AUTH_SOCK globally.
  systemd.user.sockets.gpg-agent-ssh = {
    Unit = {
      Description = "GnuPG cryptographic agent (ssh-agent emulation)";
      Documentation = "man:gpg-agent(1)";
    };
    Socket = {
      ListenStream = "%t/gnupg/S.gpg-agent.ssh";
      FileDescriptorName = "ssh";
      Service = "gpg-agent.service";
      SocketMode = "0600";
      DirectoryMode = "0700";
    };
    Install = {
      WantedBy = [ "sockets.target" ];
    };
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
