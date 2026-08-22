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
  ...
}:

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

  # ── Build role ──────────────────────────────────────────────
  # These nodes ARE builders: compile locally, never offload.
  nix = {
    distributedBuilds = lib.mkForce false;
    settings = {
      max-jobs = lib.mkForce "auto";
      trusted-users = [ "root" "beacon" ];
    };
  };

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
      hostPackages = [ config.nix.package ] ++ (with pkgs; [
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
          shutdown_timeout = "30m";
        };
        cache.enabled = true;
      };
    };
  };
  systemd.services."gitea-runner-${config.networking.hostName}".serviceConfig.TimeoutStopSec = "31m";

  # ── comin pull deployment ───────────────────────────────────
  services.comin.buildTimeout = 7200;
  beacoworks.comin = {
    enable = true;
    remote = {
      url = "https://forgejo.beaco.works/infrastructure/infra.git";
      branch = "prod";
      username = "beacon1096";
    };
    tokenSecret.sopsFile = ../../../secrets/shared/comin-forgejo-token.yaml;
  };

  # ── Sops ────────────────────────────────────────────────────
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
