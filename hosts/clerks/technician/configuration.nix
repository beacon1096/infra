# Clerk "technician" — system configuration
{ ... }:

{
  imports = [
    ../common/configuration.nix
  ];

  networking.hostName = "clerk-technician";
}
