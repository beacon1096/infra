{ inputs, pkgs, lib, config, ... }:

{
  imports = [ inputs.paseo.nixosModules.default ];

  services.paseo.package = (import ../../lib/paseo { inherit inputs pkgs; }).withNodePty;

  # A switch launched by a Paseo-managed agent must not stop its own service
  # before activation can finish. Restart Paseo separately after upgrades or
  # configuration changes that need a process restart. Guarded on enable:
  # defining the service at all when Paseo is off makes NixOS emit an
  # ExecStart-less stub unit.
  systemd.services = lib.mkIf config.services.paseo.enable {
    paseo.restartIfChanged = false;
  };
}
