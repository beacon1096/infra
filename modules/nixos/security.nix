# Security — polkit, sudo, PAM U2F (YubiKey), sops age key
{ pkgs, ... }:

{
  # Polkit — needed by many desktop services and Hyprland
  security.polkit.enable = true;

  # Sudo — keep defaults, wheel group
  security.sudo.wheelNeedsPassword = true;
  security.sudo.extraConfig = ''
    Defaults env_keep += "SSH_AUTH_SOCK"
  '';

  # Allow beacon user to use sudo without password
  security.sudo.extraRules = [{
    users = [ "beacon" ];
    commands = [{
      command = "ALL";
      options = [ "NOPASSWD" ];
    }];
  }];

  # ── PAM U2F (YubiKey FIDO2) ──────────────────────────────────
  # Touch YubiKey to login/sudo — no password needed.
  # Register keys: pamu2fcfg -o pam://beacoworks-nix -N
  # Store output in ~/.config/Yubico/u2f_keys
  security.pam.u2f = {
    enable = true;
    settings = {
      appId = "pam://beacoworks-nix";
      origin = "pam://beacoworks-nix";
      cue = false;
      interactive = true;
    };
    control = "sufficient";
  };
  security.pam.services = {
    login.u2fAuth = true;
    sudo.u2fAuth = true;
  };

  # YubiKey udev rules + smartcard daemon
  services.udev.packages = with pkgs; [ yubikey-personalization ];
  services.pcscd.enable = true;

  # sops-nix — decrypt secrets with age key derived from SSH host key
  # (per-host sops.age.sshKeyPaths is set in each host's configuration.nix)
}
