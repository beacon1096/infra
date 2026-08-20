# Clerk "technician" — per-clerk Home Manager configuration
{ lib, SECRET_DOMAIN_01, ... }:

{
  # Git identity
  programs.git.settings.user = {
    name = lib.mkForce "Technician";
    email = lib.mkForce "Technician.Clerks@${SECRET_DOMAIN_01}";
  };

  # OpenClaw configuration — uncomment when ready
  # programs.openclaw = {
  #   enable = true;
  #   documents = ./documents;
  #   config = { ... };
  #   bundledPlugins = {
  #     peekaboo.enable = true;
  #     poltergeist.enable = true;
  #     summarize.enable = true;
  #   };
  # };
}
