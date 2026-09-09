{ config, lib, ... }:

let
  cfg = config.beacoworks.remoteBuilder;
  builderHost = "100.121.229.9";
  builderName = "microserver-gen10plus";
  armBuilderHost = "172.16.80.240";
in
{
  options.beacoworks.remoteBuilder.enableArm = lib.mkEnableOption "the ms-r1 ARM builder";

  options.beacoworks.remoteBuilder.sshKey = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Client private key used by nix-daemon to authenticate to the remote builder.";
  };

  options.beacoworks.remoteBuilder.sshUser = lib.mkOption {
    type = lib.types.str;
    default = "beacon";
    description = "SSH user used to connect to the remote builder.";
  };

  config.nix = {
    distributedBuilds = config.networking.hostName != builderName || cfg.enableArm;

    # Force smaller or thermally constrained machines to offload Linux builds
    # to the home server instead of compiling locally.
    settings.max-jobs = lib.mkIf (config.networking.hostName != builderName) 0;

    buildMachines =
      lib.optionals (config.networking.hostName != builderName) [
        {
          hostName = builderHost;
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
      ]
      ++ lib.optional cfg.enableArm {
        hostName = armBuilderHost;
        protocol = "ssh-ng";
        sshUser = "beacon";
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
