# Clerk common — shared Home Manager configuration for all AI clerks
{ ... }:

{
  imports = [
    ../../../modules/home
  ];

  # Clerk-specific environment variables
  programs.zsh.initContent = ''
    # Set by sops or per-clerk home.nix
    # export ANTHROPIC_API_KEY="..."
    # export OPENCLAW_GATEWAY_TOKEN="..."
  '';
}
