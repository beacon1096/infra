{ config, lib, ... }:

let
  cfg = config.beacoworks.remoteBuilder;
  builderName = "microserver-gen10plus";

  # Home pool: the always-on gen10plus. It is also a network/edge host, so the
  # design doc (docs/infra-ops/nix-collector-build-split.md) discourages using
  # it as a general-purpose builder.
  homeBuilderHost = "100.121.229.9";
  homeBuilders = [
    {
      hostName = homeBuilderHost;
      protocol = "ssh-ng";
      sshUser = cfg.sshUser;
      sshKey = cfg.sshKey;
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUZ3SWowVFhGTTBzdXg4TllRZ04ybWh3L2NrVlZraGcwQ1R6eHFqbWwyMTAgcm9vdEBtaWNyb3NlcnZlci1nZW4xMHBsdXM=";
      systems = [
        "x86_64-linux"
        "i686-linux"
      ];
      supportedFeatures = [
        "big-parallel"
        "kvm"
      ];
      maxJobs = 8;
      speedFactor = 2;
    }
  ];

  # Harvester pool: the disposable nixbuilder-* VMs (VLAN 1096). They hold no
  # secrets, so unlike gen10plus they are the intended general/interactive
  # builder pool.
  harvesterBuilderHosts = [
    {
      hostName = "172.16.101.31";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSVBFUzZubGhmWWl4OHhGeHNEdGhmemxSdkVwYjdGZEp1MWtFbzFTdk5OVFYgbml4YnVpbGRlci0wMUBoYXJ2ZXN0ZXI=";
    }
    {
      hostName = "172.16.101.32";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUxzZXo4RkpUbk1TbThPNHB1aHFpR1FBc3Q4SmhZYWRZdWx6RDQvb2ZsUEYgbml4YnVpbGRlci0wMkBoYXJ2ZXN0ZXI=";
    }
    {
      hostName = "172.16.101.33";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUk2U1pDc1ZKQWRwckFDem9vYWhiajNMWER6c0U2OGpCU1l6cUI0STN3ZEcgbml4YnVpbGRlci0wM0BoYXJ2ZXN0ZXI=";
    }
  ];
  harvesterBuilders = map (b: {
    inherit (b) hostName publicHostKey;
    protocol = "ssh-ng";
    sshUser = cfg.sshUser;
    sshKey = cfg.sshKey;
    systems = [
      "x86_64-linux"
      "i686-linux"
    ];
    supportedFeatures = [
      "big-parallel"
      "kvm"
    ];
    maxJobs = 4;
    speedFactor = 1;
  }) harvesterBuilderHosts;

  armBuilderHost = "100.95.176.53";
in
{
  options.beacoworks.remoteBuilder = {
    enableArm = lib.mkEnableOption "the ms-r1 ARM builder";

    sshKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Client private key used by nix-daemon to authenticate to the remote builder.";
    };

    sshUser = lib.mkOption {
      type = lib.types.str;
      default = "beacon";
      description = "SSH user used to connect to the remote builder.";
    };

    pool = lib.mkOption {
      type = lib.types.enum [
        "home"
        "harvester"
      ];
      default = "home";
      description = ''
        Remote-builder pool that non-builder hosts offload to. "home" is the
        gen10plus edge host; "harvester" is the disposable nixbuilder-* pool.
      '';
    };
  };

  config.nix = {
    distributedBuilds = config.networking.hostName != builderName || cfg.enableArm;

    # Force smaller or thermally constrained machines to offload Linux builds
    # to the remote builder instead of compiling locally.
    settings.max-jobs = lib.mkIf (config.networking.hostName != builderName) 0;

    buildMachines =
      lib.optionals (config.networking.hostName != builderName) (
        if cfg.pool == "harvester" then harvesterBuilders else homeBuilders
      )
      ++ lib.optional cfg.enableArm {
        hostName = armBuilderHost;
        protocol = "ssh-ng";
        sshUser = cfg.sshUser;
        sshKey = cfg.sshKey;
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUR6cm1BRm5HbzZPb0h2RlluWSs5dkYyN0RyMXJLL3E0WXpzbk4xbGlpMncgcm9vdEBtcy1yMQo=";
        systems = [ "aarch64-linux" ];
        supportedFeatures = [
          "big-parallel"
          "kvm"
        ];
        maxJobs = 12;
        speedFactor = 2;
      };
  };
}
