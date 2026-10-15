let
  repoRoot = ../.;
  flake = builtins.getFlake (toString repoRoot);
  mkSystem = rolloutHold: flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inputs = flake.inputs; };
    modules = [
      flake.inputs.sops-nix.nixosModules.sops
      ../modules/nixos/comin.nix
      ({ lib, ... }: {
        networking.hostName = "comin-hold-test";
        fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
        boot.loader.grub.enable = false;
        system.stateVersion = lib.mkForce "25.05";
        beacoworks.comin = {
          enable = true;
          rolloutHold.enable = rolloutHold;
          remote.url = "https://example.invalid/infrastructure/infra-private.git";
          tokenSecret.sopsFile = ../secrets/shared/comin-forgejo-token.yaml;
        };
      })
    ];
  };
  enabled = mkSystem true;
  disabled = mkSystem false;
  condition = enabled.config.systemd.services.comin.unitConfig.ConditionPathExists;
in
assert condition == "!/var/lib/comin/rollout-hold";
assert !(disabled.config.systemd.services.comin.unitConfig ? ConditionPathExists);
{
  inherit condition;
  enabled = enabled.config.beacoworks.comin.rolloutHold.enable;
  default_inert = !(disabled.config.systemd.services.comin.unitConfig ? ConditionPathExists);
}
