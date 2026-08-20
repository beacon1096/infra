{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.beacoworks.comin;
  stateDir = "/var/lib/comin-darwin";
  repositoryDir = "${stateDir}/repository";
  askPass = pkgs.writeShellScript "comin-darwin-askpass" ''
    case "$1" in
      *Username*) printf '%s\n' ${lib.escapeShellArg cfg.remote.username} ;;
      *Password*) cat ${config.sops.secrets.${cfg.tokenSecret.key}.path} ;;
      *) exit 1 ;;
    esac
  '';
  updateScript = pkgs.writeShellScript "comin-darwin-update" ''
    set -euo pipefail
    umask 077

    mkdir -p ${stateDir}
    if ! mkdir ${stateDir}/lock 2>/dev/null; then
      exit 0
    fi
    trap 'rmdir ${stateDir}/lock' EXIT

    export GIT_ASKPASS=${askPass}
    export GIT_TERMINAL_PROMPT=0
    export HOME=${stateDir}
    export PATH=${
      lib.makeBinPath [
        config.nix.package
        pkgs.gitMinimal
        pkgs.openssh
      ]
    }:/run/current-system/sw/bin:/usr/bin:/bin

    if [[ ! -d ${repositoryDir}/.git ]]; then
      rm -rf ${repositoryDir}.new
      git clone --filter=blob:none --no-checkout ${lib.escapeShellArg cfg.remote.url} ${repositoryDir}.new
      mv ${repositoryDir}.new ${repositoryDir}
    fi

    git -C ${repositoryDir} fetch --prune origin \
      +refs/heads/${lib.escapeShellArg cfg.remote.branch}:refs/remotes/origin/${lib.escapeShellArg cfg.remote.branch}
    revision="$(git -C ${repositoryDir} rev-parse refs/remotes/origin/${lib.escapeShellArg cfg.remote.branch})"
    if [[ -f ${stateDir}/applied-revision ]] && [[ "$(cat ${stateDir}/applied-revision)" == "$revision" ]]; then
      exit 0
    fi

    git -C ${repositoryDir} checkout --detach --force "$revision"
    darwin-rebuild switch --flake ${repositoryDir}#${lib.escapeShellArg config.networking.hostName}
    printf '%s\n' "$revision" > ${stateDir}/applied-revision
  '';
in
{
  options.beacoworks.comin = {
    enable = lib.mkEnableOption "periodically follow a nix-darwin flake branch";
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
    };
    remote = {
      url = lib.mkOption { type = lib.types.str; };
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
      sopsFile = lib.mkOption { type = lib.types.path; };
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.${cfg.tokenSecret.key}.sopsFile = cfg.tokenSecret.sopsFile;

    launchd.daemons.comin-darwin = {
      serviceConfig = {
        Label = "works.beaco.comin-darwin";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${updateScript}"
        ];
        RunAtLoad = true;
        StartInterval = cfg.interval;
        ProcessType = "Background";
        StandardOutPath = "/var/log/comin-darwin.log";
        StandardErrorPath = "/var/log/comin-darwin.log";
      };
    };
  };
}
