# Clerk "secretary" — system configuration
{ ... }:

{
  imports = [
    ../common/configuration.nix
  ];

  networking.hostName = "clerk-secretary";
}
