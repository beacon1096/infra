# OpenSSH — enable macOS built-in sshd
#
# Required for sops-nix: SSH host ed25519 key is used to derive
# an age key for secret decryption.
{ ... }:

{
  services.openssh = {
    enable = true;
    extraConfig = ''
      AllowAgentForwarding yes
    '';
  };
}
