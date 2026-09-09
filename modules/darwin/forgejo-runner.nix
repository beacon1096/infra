{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.beacoworks.forgejoRunner;
  runnerPackages = [
    config.nix.package
  ]
  ++ (with pkgs; [
    attic-client
    bash
    coreutils
    curl
    findutils
    gawk
    gitMinimal
    gnugrep
    gnused
    gnutar
    gzip
    jq
    nodejs
    openssh
    unzip
    wget
    xz
    zstd
  ]);
  runnerLabels = lib.concatStringsSep "," cfg.labels;
  runnerState = "/var/lib/forgejo-runner";
  runnerConfig = (pkgs.formats.yaml { }).generate "forgejo-runner.yaml" {
    runner = {
      capacity = 1;
      timeout = "12h";
      shutdown_timeout = "30m";
      fetch_timeout = "5m";
    };
    cache = {
      enabled = true;
      port = 30000;
    };
  };
  runnerScript = pkgs.writeShellScript "forgejo-runner-start" ''
    set -euo pipefail
    umask 077
    mkdir -p ${runnerState}
    cd ${runnerState}
    source ${config.sops.templates."forgejo-runner.env".path}

    token_hash="$(${lib.getExe' pkgs.coreutils "sha256sum"} ${
      config.sops.templates."forgejo-runner.env".path
    } | cut -d' ' -f1)"
    old_token_hash="$(cat .token-hash 2>/dev/null || true)"
    old_labels="$(cat .labels 2>/dev/null || true)"
    if [[ ! -e .runner || "$token_hash" != "$old_token_hash" || ${lib.escapeShellArg runnerLabels} != "$old_labels" ]]; then
      rm -f .runner
      ${lib.getExe pkgs.forgejo-runner} register --no-interactive \
        --instance https://forgejo.beaco.works \
        --token "$TOKEN" \
        --name ${lib.escapeShellArg config.networking.hostName} \
        --labels ${lib.escapeShellArg runnerLabels} \
        --config ${runnerConfig}
      printf '%s' "$token_hash" > .token-hash
      printf '%s' ${lib.escapeShellArg runnerLabels} > .labels
    fi

    exec ${lib.getExe pkgs.forgejo-runner} daemon --config ${runnerConfig}
  '';
in
{
  options.beacoworks.forgejoRunner = {
    enable = lib.mkEnableOption "Forgejo host runner";
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nix-builder-aarch64-darwin:host"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    programs.ssh.knownHosts.linux-builder.publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJBWcxb/Blaqt1auOtE+F8QUWrUotiC5qBJ+UuEWdVCb";

    nix = {
      linux-builder = {
        enable = true;
        maxJobs = 4;
        config = {
          virtualisation = {
            cores = lib.mkForce 6;
            memorySize = lib.mkForce 12288;
          };
          nix.settings.max-jobs = 4;
        };
      };
      settings.max-jobs = 4;
    };

    sops.secrets."forgejo/runner/token" = {
      sopsFile = ../../secrets/shared/forgejo-runner.yaml;
    };
    sops.templates."forgejo-runner.env".content = ''
      TOKEN=${config.sops.placeholder."forgejo/runner/token"}
    '';

    environment.systemPackages = runnerPackages ++ [ pkgs.forgejo-runner ];
    launchd.daemons.forgejo-runner = {
      environment = {
        HOME = runnerState;
        PATH = lib.makeBinPath runnerPackages;
      };
      serviceConfig = {
        Label = "works.beaco.forgejo-runner";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${runnerScript}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        WorkingDirectory = "/var/lib";
        StandardOutPath = "/var/log/forgejo-runner.log";
        StandardErrorPath = "/var/log/forgejo-runner.log";
      };
    };
  };
}
