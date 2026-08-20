# NixOS Installer ISO — host entry point
#
# This is a thin wrapper that pulls in the installer module.
# The actual configuration lives in modules/nixos/installer.nix.
#
# Build:
#   nix build .#installer-iso
#   dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress
{ inputs, ... }:

{
  imports = [
    ../../modules/nixos/installer.nix
  ];
}
