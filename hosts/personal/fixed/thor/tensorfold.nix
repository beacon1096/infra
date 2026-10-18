{ config, lib, pkgs, ... }:

let
  cfg = config.services.thorTensorFold;
  runtimeDir = "/run/thor-tensorfold";
  run = pkgs.writeShellApplication {
    name = "thor-tensorfold-run";
    runtimeInputs = with pkgs; [ coreutils docker gawk jq python3 ];
    text = builtins.readFile ./tensorfold/run.sh;
  };
  guard = pkgs.writeShellApplication {
    name = "thor-tensorfold-memwatch";
    runtimeInputs = with pkgs; [ coreutils gawk systemd ];
    text = builtins.readFile ./flash-next/memwatch.sh;
  };
  otherUnits = [
    "thor-inference.service"
    "thor-inference-experiment.service"
    "thor-inference-memwatch.service"
    "thor-inference-experiment-memwatch.service"
    "thor-inference-healthcheck.service"
    "thor-inference-healthcheck.timer"
    "thor-flash-next.service"
    "thor-flash-next-memwatch.service"
  ];
in
{
  options.services.thorTensorFold.parallel = lib.mkOption {
    type = lib.types.enum [ 1 8 ];
    default = 1;
    description = "Explicit trial concurrency; the vendor profile uses eight streams.";
  };

  config.systemd.services = {
    thor-tensorfold = {
      description = "Thor Flash Next TensorFold native (explicit start only)";
      requires = [ "docker.service" "thor-tensorfold-memwatch.service" ];
      bindsTo = [ "thor-tensorfold-memwatch.service" ];
      after = [ "docker.service" "thor-tensorfold-memwatch.service" ] ++ otherUnits;
      conflicts = otherUnits;
      environment = {
        MODEL_ROOT = "/var/lib/thor-inference/tensorfold/1464274120d3";
        CACHE_DIR = "/var/lib/thor-tensorfold";
        RUNTIME_DIR = runtimeDir;
        PARALLEL = toString cfg.parallel;
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = "${run}/bin/thor-tensorfold-run";
        ExecStop = "${run}/bin/thor-tensorfold-run cleanup";
        ExecStopPost = "${run}/bin/thor-tensorfold-run cleanup";
        Restart = "no";
        TimeoutStartSec = 60;
        TimeoutStopSec = 45;
        StateDirectory = "thor-tensorfold";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "thor-tensorfold";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
    };
    thor-tensorfold-memwatch = {
      description = "Host memory stop guard for Thor TensorFold";
      partOf = [ "thor-tensorfold.service" ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        ExecStart = "${guard}/bin/thor-tensorfold-memwatch thor-tensorfold.service ${runtimeDir}";
        Restart = "no";
        RuntimeDirectory = "thor-tensorfold";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
    };
  };
}
