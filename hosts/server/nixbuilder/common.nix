# nixbuilder — shared config for the Harvester NixOS build/runner nodes.
#
# Three near-identical VMs on the Harvester HCI cluster (VLAN 1096 /
# 172.16.101.0/24, DHCP-reserved on the RB5009 by MAC). Each runs a Forgejo
# Actions runner (label nix-builder:host) and builds Nix locally instead of
# offloading. Per-host wrappers only set networking.hostName.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  maintenanceSchedules = {
    nixbuilder-01 = {
      drain = "Sun,Wed *-*-* 15:00:00";
      maintain = "Mon,Thu *-*-* 03:15:00";
      resume = "Mon,Thu *-*-* 04:25:00";
    };
    nixbuilder-02 = {
      drain = "Mon,Thu *-*-* 15:00:00";
      maintain = "Tue,Fri *-*-* 03:15:00";
      resume = "Tue,Fri *-*-* 04:25:00";
    };
    nixbuilder-03 = {
      drain = "Tue,Fri *-*-* 15:00:00";
      maintain = "Wed,Sat *-*-* 03:15:00";
      resume = "Wed,Sat *-*-* 04:25:00";
    };
  };
  maintenanceSchedule = maintenanceSchedules.${config.networking.hostName};
  maintenanceMarker = "/run/nixbuilder-maintenance";
  runnerService = "gitea-runner-${utils.escapeSystemdPath config.networking.hostName}.service";
  runnerServiceShell = lib.escapeShellArg runnerService;
in
{
  imports = [
    ../common/configuration.nix
    ../../../modules/common/attic-cache.nix
    ../../../modules/nixos/comin.nix
    ./disko.nix
  ];

  # ── Networking ──────────────────────────────────────────────
  # DHCP on the single virtio NIC; the RB5009 hands out the reserved
  # 172.16.101.3x address keyed on the pinned VM MAC.
  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services.qemuGuest.enable = true;

  networking.hosts."172.16.20.11" = [
    "forgejo.beaco.works"
    "nix.beaco.works"
  ];

  # ── Build role ──────────────────────────────────────────────
  # These nodes ARE builders: compile locally, never offload.
  nix = {
    distributedBuilds = lib.mkForce false;
    settings = {
      # Forgejo and Attic currently traverse Cloudflare from this VLAN;
      # large HTTP/2 transfers intermittently reset mid-stream.
      http2 = false;
      max-jobs = lib.mkForce "auto";
      trusted-users = [
        "root"
        "beacon"
      ];
    };
  };
  environment.etc.gitconfig.text = ''
    [http]
      version = HTTP/1.1
  '';

  # ── Forgejo Actions runner ──────────────────────────────────
  sops.secrets."forgejo/runner/token" = {
    sopsFile = ../../../secrets/shared/forgejo-runner.yaml;
  };
  sops.templates."forgejo-runner.env".content = ''
    TOKEN=${config.sops.placeholder."forgejo/runner/token"}
  '';

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.${config.networking.hostName} = {
      enable = true;
      name = config.networking.hostName;
      url = "https://forgejo.beaco.works";
      tokenFile = config.sops.templates."forgejo-runner.env".path;
      labels = [ "nix-builder:host" ];
      hostPackages = [
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
        python3
        unzip
        wget
        xz
        zstd
      ]);
      settings = {
        runner = {
          capacity = 1;
          timeout = "12h";
          shutdown_timeout = "12h";
        };
        cache.enabled = true;
      };
    };
  };

  nix.gc.automatic = lib.mkForce false;
  nix.optimise.automatic = lib.mkForce false;

  systemd.services = {
    "gitea-runner-${utils.escapeSystemdPath config.networking.hostName}" = {
      unitConfig.ConditionPathExists = "!${maintenanceMarker}";
      serviceConfig.TimeoutStopSec = "12h5m";
    };

    nixbuilder-runner-drain = {
      description = "Drain the Forgejo runner before Nix store maintenance";
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "12h10m";
      };
      path = [
        pkgs.coreutils
        pkgs.systemd
      ];
      script = ''
        install -m 000 /dev/null ${maintenanceMarker}
        systemctl stop ${runnerServiceShell}
      '';
    };

    nixbuilder-store-maintenance = {
      description = "Garbage collect and optimise the Nix builder store";
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "1h";
        TimeoutStopSec = "5m";
      };
      path = [
        config.nix.package
        pkgs.coreutils
        pkgs.systemd
      ];
      script = ''
        runner_state="$(systemctl show --property=ActiveState --value ${runnerServiceShell})"
        if [ ! -e ${maintenanceMarker} ] || [ "$runner_state" != inactive ]; then
          echo "Skipping store maintenance: runner state is $runner_state"
          exit 0
        fi

        nix-collect-garbage --delete-older-than 7d
        nix-store --optimise
      '';
    };

    nixbuilder-runner-resume = {
      description = "Resume the Forgejo runner after Nix store maintenance";
      after = [ "nixbuilder-store-maintenance.service" ];
      serviceConfig.Type = "oneshot";
      path = [
        pkgs.coreutils
        pkgs.systemd
      ];
      script = ''
        rm -f ${maintenanceMarker}
        systemctl start ${runnerServiceShell}
      '';
    };
  };

  systemd.timers = {
    nixbuilder-runner-drain = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = maintenanceSchedule.drain;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };
    nixbuilder-store-maintenance = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = maintenanceSchedule.maintain;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };
    nixbuilder-runner-resume = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = maintenanceSchedule.resume;
        Persistent = true;
        RandomizedDelaySec = "0";
      };
    };
  };

  beacoworks.comin.enable = lib.mkDefault false;

  # ── Sops ────────────────────────────────────────────────────
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
