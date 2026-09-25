{ inputs, pkgs, ... }:

{
  imports = [ inputs.paseo.nixosModules.default ];

  services.paseo.package = (import ../../lib/paseo { inherit inputs pkgs; }).paseo;

  # A switch launched by a Paseo-managed agent must not stop its own service
  # before activation can finish. Restart Paseo separately after upgrades or
  # configuration changes that need a process restart.
  systemd.services.paseo.restartIfChanged = false;
}
