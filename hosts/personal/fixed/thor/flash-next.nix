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
  mtpArguments = [
    "--speculative-algorithm" "NEXTN"
    "--speculative-num-steps" "3"
    "--speculative-eagle-topk" "1"
    "--speculative-num-draft-tokens" "4"
    "--speculative-draft-model-path" "/models/draft"
    "--speculative-draft-model-quantization" "modelopt_mixed"
  ];
  metricsArguments = lib.optionals config.services.thorFlashNext.metrics [ "--enable-metrics" ];
  tokenMapArguments = lib.optionals config.services.thorFlashNext.tokenMap
    [ "--speculative-token-map" "/vocab-maps/vocab-32768-corpus.pt" ];
  setArgument = name: value: arguments:
    let index = lib.lists.findFirstIndex (item: item == name) null arguments;
    in
    assert index != null;
    lib.take index arguments ++ [ name value ] ++ lib.drop (index + 2) arguments;
  adjustArguments = arguments:
    let
      withTokens =
        if config.services.thorFlashNext.maxTotalTokens == null then arguments
        else setArgument "--max-total-tokens" (toString config.services.thorFlashNext.maxTotalTokens) arguments;
      withState =
        if config.services.thorFlashNext.mambaStateDtype == null then withTokens
        else setArgument "--mamba-ssm-dtype" config.services.thorFlashNext.mambaStateDtype withTokens;
      withKv =
        if config.services.thorFlashNext.kvCacheDtype == null then withState
        else setArgument "--kv-cache-dtype" config.services.thorFlashNext.kvCacheDtype withState;
      withChunk =
        if config.services.thorFlashNext.chunkedPrefillSize == null then withKv
        else setArgument "--chunked-prefill-size" (toString config.services.thorFlashNext.chunkedPrefillSize) withKv;
      withFp8 =
        if config.services.thorFlashNext.fp8GemmBackend == null then withChunk
        else setArgument "--fp8-gemm-backend" config.services.thorFlashNext.fp8GemmBackend withChunk;
      withMoe =
        if config.services.thorFlashNext.moeRunnerBackend == null then withFp8
        else setArgument "--moe-runner-backend" config.services.thorFlashNext.moeRunnerBackend withFp8;
      withFp4 =
        if config.services.thorFlashNext.fp4GemmBackend == null then withMoe
        else setArgument "--fp4-gemm-backend" config.services.thorFlashNext.fp4GemmBackend withMoe;
    in
    withFp4 ++ metricsArguments ++ tokenMapArguments;
  graphBaseline = if config.services.thorFlashNext.decodeGraph then decodeGraphBaseline else baseline;
  mtpBaseline = graphBaseline // {
    name = graphBaseline.name + " + NEXTN full-vocab MTP";
    arguments = graphBaseline.arguments ++ mtpArguments;
  };
  stage2 = config.services.thorFlashNext.modelSource == "uncensored-stage2";
  modelDir =
    if stage2 then config.services.thorFlashNext.uncensoredStage2Dir else baseline.model_dir;
  targetDir = if stage2 then modelDir else "${modelDir}/target";
  activeBaseline =
    let
      base =
        if config.services.thorFlashNext.mtp then mtpBaseline
        else if config.services.thorFlashNext.decodeGraph then decodeGraphBaseline
        else baseline;
    in
    if stage2 then
      builtins.removeAttrs (base // {
        name = "thor-flash-next uncensored stage2 (modelopt_mixed derived)";
        model_dir = modelDir;
        target_repository = "jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4";
        target_revision = config.services.thorFlashNext.uncensoredStage2Revision;
        configuration_revision = "thor-stage2-mixed-converter";
        conversion_manifest_sha256 = config.services.thorFlashNext.uncensoredStage2ManifestSha256;
      }) [ "prepared_observation" ]
    else base;
  activeBaselineWithOverlay = activeBaseline // {
    arguments = adjustArguments activeBaseline.arguments;
  };
  usesGeneratedBaseline = stage2
    || config.services.thorFlashNext.mtp
    || config.services.thorFlashNext.decodeGraph
    || config.services.thorFlashNext.metrics
    || config.services.thorFlashNext.maxTotalTokens != null
    || config.services.thorFlashNext.mambaStateDtype != null
    || config.services.thorFlashNext.kvCacheDtype != null
    || config.services.thorFlashNext.chunkedPrefillSize != null
    || config.services.thorFlashNext.fp8GemmBackend != null
    || config.services.thorFlashNext.moeRunnerBackend != null
    || config.services.thorFlashNext.fp4GemmBackend != null;
  baselineName =
    if stage2 then
      "thor-flash-next-stage2-mixed.json"
    else if config.services.thorFlashNext.mtp then
      (if config.services.thorFlashNext.tokenMap then
        "thor-flash-next-NEXTN-mtp-tokenmap.json"
      else
        "thor-flash-next-NEXTN-mtp.json")
    else if config.services.thorFlashNext.decodeGraph then
      "thor-flash-next-C1-decodeGraph.json"
    else if config.services.thorFlashNext.metrics then
      "thor-flash-next-metrics.json"
    else
      "thor-flash-next-adjusted.json";
  baselineFile =
    if usesGeneratedBaseline then
      pkgs.writeText baselineName (builtins.toJSON activeBaselineWithOverlay)
    else ./flash-next/baseline.json;
  draftDir = "${baseline.model_dir}/draft";
  optimizationDir = "${baseline.model_dir}/optimization";
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
  options.services.thorFlashNext.runtimeMaxSec = lib.mkOption {
    type = lib.types.ints.positive;
    default = 3600;
    description = "Bounded runtime for an explicitly started Flash Next experiment.";
  };
  options.services.thorFlashNext.mtp = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable native NEXTN MTP with the full draft vocabulary (3 steps, topk 1, 4 draft tokens).";
  };
  options.services.thorFlashNext.metrics = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Expose the Prometheus /metrics endpoint for the running server.";
  };
  options.services.thorFlashNext.tokenMap = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable the 32768-token draft token map (requires mtp = true).";
  };
  options.services.thorFlashNext.maxTotalTokens = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = null;
    description = "Override --max-total-tokens (KV budget) for long-context experiments.";
  };
  options.services.thorFlashNext.mambaStateDtype = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "float32" "bfloat16" ]);
    default = null;
    description = "Override --mamba-ssm-dtype for the recurrent state precision axis.";
  };
  options.services.thorFlashNext.kvCacheDtype = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "bfloat16" "fp8_e4m3" ]);
    default = null;
    description = "Override --kv-cache-dtype for the KV precision axis.";
  };
  options.services.thorFlashNext.chunkedPrefillSize = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = null;
    description = "Override --chunked-prefill-size for long-prefill scheduling experiments.";
  };
  options.services.thorFlashNext.fp8GemmBackend = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "auto" "deep_gemm" "flashinfer_trtllm" "flashinfer_cutlass" "flashinfer_deepgemm" "flashinfer_cutedsl" "cutlass" "triton" "aiter" ]);
    default = null;
    description = "Override --fp8-gemm-backend for the dense FP8 GEMM path.";
  };
  options.services.thorFlashNext.moeRunnerBackend = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "auto" "deep_gemm" "triton" "flashinfer_trtllm" "flashinfer_cutlass" "cutlass" "marlin" "humming" ]);
    default = null;
    description = "Override --moe-runner-backend for the MoE GEMM path.";
  };
  options.services.thorFlashNext.fp4GemmBackend = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "auto" "flashinfer_cudnn" "flashinfer_cutedsl" "flashinfer_cutlass" "flashinfer_trtllm" "marlin" ]);
    default = null;
    description = "Override --fp4-gemm-backend for the FP4 GEMM path.";
  };
  options.services.thorFlashNext.w8a8ShapeLog = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable the patched dense-FP8 kernel shape log (SGLANG_W8A8_SHAPE_LOG=/tmp/w8a8-shapes.log) for offline shape inventory.";
  };
  options.services.thorFlashNext.gdnStateDump = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Dump per-layer GDN SSM state to this host directory (uses the diagnostic gdn_backend.py overlay) for state-dtype drift analysis.";
  };
  options.services.thorFlashNext.gdnStateDumpLayers = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Comma-separated GDN layer ids to dump; unset or \"all\" dumps every layer. Only used with gdnStateDump.";
  };
  options.services.thorFlashNext.modelSource = lib.mkOption {
    type = lib.types.enum [ "radixark" "uncensored-stage2" ];
    default = "radixark";
    description = "Which target artifact to serve. 'radixark' = the prepared production checkpoint; 'uncensored-stage2' = the derived modelopt_mixed uncensored candidate (flat model dir, no prepared pipeline).";
  };
  options.services.thorFlashNext.uncensoredStage2Dir = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Flat model directory for modelSource = uncensored-stage2 (the Stage-2 mixed artifact).";
  };
  options.services.thorFlashNext.uncensoredStage2Revision = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Upstream revision pinned in the Stage-2 baseline (jpezzulli HF revision); recorded in the generated baseline.";
  };
  options.services.thorFlashNext.uncensoredStage2ManifestSha256 = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Expected sha256 of the Stage-2 artifact's conversion-manifest.json; verified by run.sh at startup.";
  };

  config = {
    assertions = [{
      assertion = !config.services.thorFlashNext.tokenMap || config.services.thorFlashNext.mtp;
      message = "services.thorFlashNext.tokenMap requires services.thorFlashNext.mtp";
    } {
      assertion = !stage2 || (config.services.thorFlashNext.uncensoredStage2Dir != null
        && config.services.thorFlashNext.uncensoredStage2ManifestSha256 != null);
      message = "services.thorFlashNext.modelSource = uncensored-stage2 requires uncensoredStage2Dir and uncensoredStage2ManifestSha256";
    }];
    systemd.services.thor-flash-next = {
      description = "Thor Flash Next mixed-target-only baseline (short-input experiment)";
      requires = [ "docker.service" "thor-flash-next-memwatch.service" ];
      bindsTo = [ "thor-flash-next-memwatch.service" ];
      after = [ "docker.service" "thor-flash-next-memwatch.service" ] ++ legacyUnits;
      conflicts = legacyUnits;
      environment = {
        BASELINE_FILE = "${baselineFile}";
        IMAGE = baseline.image;
        MODEL_DIR = modelDir;
        MODEL_ROOT = modelDir;
        TARGET_DIR = targetDir;
        RUNTIME_DIR = runtimeDir;
        CACHE_DIR = "/var/lib/thor-flash-next/${builtins.baseNameOf modelDir}/runtime-cache";
        DRAFT_DIR = if config.services.thorFlashNext.mtp then draftDir else "";
        OPTIMIZATION_DIR = if config.services.thorFlashNext.tokenMap then optimizationDir else "";
        W8A8_SHAPE_LOG = if config.services.thorFlashNext.w8a8ShapeLog then "/tmp/w8a8-shapes.log" else "";
        GDN_STATE_DUMP = if config.services.thorFlashNext.gdnStateDump == null then "" else config.services.thorFlashNext.gdnStateDump;
        GDN_STATE_DUMP_LAYERS = if config.services.thorFlashNext.gdnStateDumpLayers == null then "" else config.services.thorFlashNext.gdnStateDumpLayers;
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
        RuntimeMaxSec = config.services.thorFlashNext.runtimeMaxSec;
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
