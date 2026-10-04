{ config, lib, pkgs, ... }:

let
  baseline = builtins.fromJSON (builtins.readFile ./flash-next/baseline.json);
  decodePositions = lib.filter
    (index: builtins.elemAt baseline.arguments index == "--cuda-graph-backend-decode")
    (lib.range 0 (builtins.length baseline.arguments - 1));
  decodeGraphBaseline =
    assert builtins.length decodePositions == 1;
    let index = builtins.head decodePositions; in
    assert builtins.elemAt baseline.arguments (index + 1) == "disabled";
    assert !(builtins.elem "--cuda-graph-max-bs-decode" baseline.arguments);
    baseline // {
      name = "mixed-target-only C1 decodeGraph control (G1)";
      arguments = lib.take (index + 1) baseline.arguments
        ++ [ "full" ]
        ++ lib.drop (index + 2) baseline.arguments
        ++ [ "--cuda-graph-max-bs-decode" "1" ];
    };
  baselineFile = if config.services.thorFlashNext.decodeGraph then
    pkgs.writeText "thor-flash-next-C1-decodeGraph.json" (builtins.toJSON decodeGraphBaseline)
  else ./flash-next/baseline.json;
  runtimeDir = "/run/thor-flash-next";
  fa4Wheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/b1/28/6e0452ec7c42934267be78aa4b2e7b1f886084e9750d8b1ba7ecff2c20f5/flash_attn_4-4.0.0b31-py3-none-any.whl";
    hash = "sha256-btpYkLKekPxG4ZpHtAGO/658BC917oqq7r0/VszYLt8=";
  };
  # Keep the image's FFI 0.1.11: TileLang 0.1.12 aborts with newer FFI.
  fa4Layer = pkgs.runCommand "thor-flash-next-fa4-python" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    mkdir -p "$out"
    unzip -q ${fa4Wheel} -d "$out"
  '';
  run = pkgs.writeShellApplication {
    name = "thor-flash-next-run";
    runtimeInputs = with pkgs; [ coreutils docker gawk jq ];
    text = builtins.readFile ./flash-next/run.sh;
  };
  prepare = pkgs.writeShellApplication {
    name = "thor-flash-next-prepare";
    runtimeInputs = with pkgs; [ coreutils docker jq patch ];
    text = builtins.readFile ./flash-next/prepare.sh;
  };
  guard = pkgs.writeShellApplication {
    name = "thor-flash-next-memwatch";
    runtimeInputs = with pkgs; [ coreutils gawk systemd ];
    text = builtins.readFile ./flash-next/memwatch.sh;
  };
  legacyUnits = [
    "thor-inference.service"
    "thor-inference-experiment.service"
    "thor-inference-memwatch.service"
    "thor-inference-experiment-memwatch.service"
    "thor-inference-healthcheck.service"
    "thor-inference-healthcheck.timer"
  ];
in
{
  options.services.thorFlashNext.decodeGraph = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable the C1 decodeGraph control (G1): full decode graphs at batch size 1.";
  };

  config = {
    systemd.services.thor-flash-next = {
      description = "Thor Flash Next mixed-target-only baseline (short-input experiment)";
      requires = [ "docker.service" "thor-flash-next-memwatch.service" ];
      bindsTo = [ "thor-flash-next-memwatch.service" ];
      after = [ "docker.service" "thor-flash-next-memwatch.service" ] ++ legacyUnits;
      conflicts = legacyUnits;
      environment = {
        BASELINE_FILE = "${baselineFile}";
        IMAGE = baseline.image;
        MODEL_DIR = baseline.model_dir;
        RUNTIME_DIR = runtimeDir;
        CACHE_DIR = "/var/lib/thor-flash-next/${builtins.baseNameOf baseline.model_dir}/runtime-cache";
        FA4_LAYER = toString fa4Layer;
        PREPARE_PROGRAM = "${prepare}/bin/thor-flash-next-prepare";
        PATCH_DIR = "${./flash-next}";
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = "${run}/bin/thor-flash-next-run";
        ExecStop = "${run}/bin/thor-flash-next-run cleanup";
        ExecStopPost = "${run}/bin/thor-flash-next-run cleanup";
        Restart = "no";
        RuntimeMaxSec = 3600;
        TimeoutStartSec = 60;
        TimeoutStopSec = 45;
        StateDirectory = "thor-flash-next";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "thor-flash-next";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    systemd.services.thor-flash-next-memwatch = {
      description = "Host memory stop guard for Thor Flash Next";
      partOf = [ "thor-flash-next.service" ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        ExecStart = "${guard}/bin/thor-flash-next-memwatch thor-flash-next.service ${runtimeDir}";
        Restart = "no";
        RuntimeDirectory = "thor-flash-next";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
    };
  };
}
