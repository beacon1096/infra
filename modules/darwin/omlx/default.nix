{ config, lib, pkgs, ... }:

let
  cfg = config.services.omlx;
  home = config.users.users.${config.system.primaryUser}.home;
  json = pkgs.formats.json { };
  manifest = json.generate "omlx-models.json" { inherit (cfg) models; };
  proxyArgs = lib.optionals (cfg.proxyUrl != null) [
    "--http-proxy"
    cfg.proxyUrl
    "--https-proxy"
    cfg.proxyUrl
  ];
  sync = pkgs.writeShellScriptBin "omlx-sync" ''
    ${lib.optionalString (cfg.proxyUrl != null) ''
      export http_proxy=${lib.escapeShellArg cfg.proxyUrl}
      export https_proxy=${lib.escapeShellArg cfg.proxyUrl}
      export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
    ''}
    exec ${cfg.package}/Applications/oMLX.app/Contents/MacOS/omlx-cluster-python \
      ${./sync-models.py} --manifest ${manifest} \
      --model-dir ${lib.escapeShellArg cfg.modelDir} \
      --base-path ${lib.escapeShellArg cfg.basePath} "$@"
  '';
in
{
  options.services.omlx = {
    enable = lib.mkEnableOption "oMLX with a pinned application and model manifest";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../../packages/omlx { };
    };
    basePath = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.omlx";
    };
    modelDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.basePath}/models";
    };
    proxyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    models = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          repo = lib.mkOption { type = lib.types.str; };
          revision = lib.mkOption { type = lib.types.strMatching "[0-9a-f]{40}"; };
          settings = lib.mkOption {
            type = json.type;
            default = { };
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package sync ];
    system.activationScripts.preActivation.text = ''
      /usr/bin/install -d -m 700 -o ${lib.escapeShellArg config.system.primaryUser} \
        ${lib.escapeShellArg cfg.basePath} ${lib.escapeShellArg "${cfg.basePath}/logs"}
    '';
    launchd.user.agents.omlx = {
      script = ''
        set -eu
        ${sync}/bin/omlx-sync --configure-only
        exec ${lib.getExe cfg.package} serve \
          --base-path ${lib.escapeShellArg cfg.basePath} \
          --model-dir ${lib.escapeShellArg cfg.modelDir} \
          ${lib.escapeShellArgs (proxyArgs ++ cfg.extraArgs)}
      '';
      serviceConfig = {
        Label = "works.beaco.omlx";
        WorkingDirectory = home;
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = "${cfg.basePath}/logs/launchd.out.log";
        StandardErrorPath = "${cfg.basePath}/logs/launchd.err.log";
      };
    };
    system.build.omlx = pkgs.linkFarm "omlx-deployment" [
      { name = "package"; path = cfg.package; }
      { name = "sync"; path = sync; }
      { name = "manifest.json"; path = manifest; }
      {
        name = "agent.plist";
        path = config.environment.userLaunchAgents."works.beaco.omlx.plist".source;
      }
    ];
  };
}
