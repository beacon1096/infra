{ config, inputs, lib, ... }:

let
  cfg = config.beacoworks.comin;
in
{
  imports = [ inputs.comin.nixosModules.comin ];

  options.beacoworks.comin = {
    enable = lib.mkEnableOption "host-local comin pull deployment";

    remote = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "origin";
      };

      url = lib.mkOption {
        type = lib.types.str;
      };

      branch = lib.mkOption {
        type = lib.types.str;
        default = "prod";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "comin";
      };
    };

    tokenSecret = {
      key = lib.mkOption {
        type = lib.types.str;
        default = "comin/forgejo/access_token";
      };

      sopsFile = lib.mkOption {
        type = lib.types.path;
      };
    };

    machineId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.tokenSecret.key} = {
      sopsFile = cfg.tokenSecret.sopsFile;
    };

    services.comin = {
      enable = true;
      machineId = cfg.machineId;
      # Upstream only exports GIT_ASKPASS when submodules are enabled. Nix
      # needs the same credentials while fetching private nested flake inputs.
      submodules = true;
      remotes = [
        {
          name = cfg.remote.name;
          url = cfg.remote.url;
          auth = {
            username = cfg.remote.username;
            access_token_path = config.sops.secrets.${cfg.tokenSecret.key}.path;
          };
          branches.main.name = cfg.remote.branch;
          branches.testing.name = "";
        }
      ];
    };
  };
}
