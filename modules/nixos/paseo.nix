{ config, inputs, pkgs, ... }:

{
  imports = [ inputs.paseo.nixosModules.default ];

  # fetchNpmDeps hashes can change with the downstream nixpkgs revision.
  services.paseo.package = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    npmDepsHash = "sha256-oXz8hMk+5DlTYK8OndUAjB+RJMDbPqobVGXLFeoH++o=";
  };

  # A switch launched by a Paseo-managed agent must not stop its own service
  # before activation can finish. Restart Paseo separately after upgrades or
  # configuration changes that need a process restart.
  systemd.services.paseo.restartIfChanged = false;
  systemd.services.paseo.serviceConfig.EnvironmentFile =
    config.sops.templates."paseo-mcp.env".path;
}
