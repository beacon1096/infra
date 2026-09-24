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
  runnerLabel = "works.beaco.forgejo-runner";
  runnerPlist = "/Library/LaunchDaemons/${runnerLabel}.plist";
  # Cleared on boot, like /run on NixOS: a host that reboots mid-window comes
  # back with the runner enabled rather than silently drained forever.
  maintenanceMarker = "/var/run/forgejo-runner-maintenance";
  runnerConfig = (pkgs.formats.yaml { }).generate "forgejo-runner.yaml" {
    runner = {
      capacity = 1;
      timeout = "12h";
      # Matches `timeout`, as on the NixOS builders: on SIGTERM the runner
      # should see the job it accepted through to the end, not guillotine it
      # partway. ExitTimeOut on the daemon bounds the wait.
      shutdown_timeout = "12h";
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

    maintenance = {
      drain = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {
          Weekday = 6;
          Hour = 15;
          Minute = 0;
        };
        description = ''
          When to stop accepting jobs. Leave a wide gap before `collect`: a job
          that started just before this fires still has the runner's 12h budget
          to finish, and maintenance skips itself while one is live.
        '';
      };
      collect = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {
          Weekday = 0;
          Hour = 3;
          Minute = 15;
        };
        description = "When to garbage collect and optimise the drained store.";
      };
      resume = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {
          Weekday = 0;
          Hour = 4;
          Minute = 25;
        };
        description = "When to let the runner pick up jobs again.";
      };
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
        Label = runnerLabel;
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "/bin/wait4path /nix/store && exec ${runnerScript}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        # forgejo-runner finishes its current job on SIGTERM (shutdown_timeout
        # above). Give launchd room for a job that started just before the
        # drain instead of SIGKILLing it after the 20s default.
        ExitTimeOut = 45000;
        WorkingDirectory = "/var/lib";
        StandardOutPath = "/var/log/forgejo-runner.log";
        StandardErrorPath = "/var/log/forgejo-runner.log";
      };
    };

    # Nix's own schedulers are unaware of CI. Left enabled, nix-collect-garbage
    # deletes store paths out from under a running build and the job dies with
    # "path '/nix/store/...' is not valid". The NixOS builders solved this by
    # draining the runner around maintenance; darwin never got the same
    # treatment, so its weekly GC raced every long ARM build.
    nix.gc.automatic = lib.mkForce false;
    nix.optimise.automatic = lib.mkForce false;

    # launchd has no ConditionPathExists, and KeepAlive.PathState is no
    # substitute -- measured on this host, it neither stops a running job when
    # the path appears nor suppresses the respawn after one is killed. So the
    # drain unloads the daemon outright and the resume bootstraps it back.
    launchd.daemons.forgejo-runner-drain = {
      serviceConfig = {
        Label = "works.beaco.forgejo-runner-drain";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            /usr/bin/install -m 000 /dev/null ${maintenanceMarker}
            /bin/launchctl bootout system/${runnerLabel} 2>&1 || true
          ''
        ];
        StartCalendarInterval = [ cfg.maintenance.drain ];
        StandardOutPath = "/var/log/forgejo-runner-maintenance.log";
        StandardErrorPath = "/var/log/forgejo-runner-maintenance.log";
      };
    };

    launchd.daemons.forgejo-runner-maintenance = {
      environment.PATH = lib.makeBinPath [
        config.nix.package
        pkgs.coreutils
      ];
      serviceConfig = {
        Label = "works.beaco.forgejo-runner-maintenance";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            /bin/wait4path /nix/store || exit 0
            if [ ! -e ${maintenanceMarker} ]; then
              echo "Skipping store maintenance: no drain marker"
              exit 0
            fi
            # `bootout` returns before the runner has finished exiting, and a
            # darwin-rebuild activation mid-window loads it straight back. A
            # loaded daemon therefore means a build may be live: skip this
            # week rather than collect paths out from under it.
            if /bin/launchctl print system/${runnerLabel} >/dev/null 2>&1; then
              echo "Skipping store maintenance: runner is loaded again"
              exit 0
            fi
            nix-collect-garbage --delete-older-than 7d
            nix-store --optimise
          ''
        ];
        StartCalendarInterval = [ cfg.maintenance.collect ];
        StandardOutPath = "/var/log/forgejo-runner-maintenance.log";
        StandardErrorPath = "/var/log/forgejo-runner-maintenance.log";
      };
    };

    launchd.daemons.forgejo-runner-resume = {
      serviceConfig = {
        Label = "works.beaco.forgejo-runner-resume";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            /bin/rm -f ${maintenanceMarker}
            /bin/launchctl bootstrap system ${runnerPlist} 2>&1 || true
          ''
        ];
        StartCalendarInterval = [ cfg.maintenance.resume ];
        StandardOutPath = "/var/log/forgejo-runner-maintenance.log";
        StandardErrorPath = "/var/log/forgejo-runner-maintenance.log";
      };
    };
  };
}
