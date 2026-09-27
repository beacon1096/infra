{ lib, pkgs, ... }:

let
  image = "sha256:b4625e472cec3abf4b811a7d308704e757e92c324db52f52b8dc5721877934da";
  state = "/var/lib/thor-inference";
  target = "lazycat-qwen38-target-e5ff498";
  draft = "lazycat-qwen38-draft-bd7a934";
  patches = ./inference;
  manifest = builtins.fromJSON (builtins.readFile ./inference/manifest.json);
  fa4Wheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/b1/28/6e0452ec7c42934267be78aa4b2e7b1f886084e9750d8b1ba7ecff2c20f5/flash_attn_4-4.0.0b31-py3-none-any.whl";
    hash = "sha256-btpYkLKekPxG4ZpHtAGO/658BC917oqq7r0/VszYLt8=";
  };
  tvmFfiWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/b4/11/3791b1c9967c2863313221b37889e0cd1181d56dc815a2f6e7e6d1bf342d/apache_tvm_ffi-0.1.14.post0-cp312-cp312-manylinux_2_24_aarch64.manylinux_2_28_aarch64.whl";
    hash = "sha256-jvsiNEc5gCccZl7qQL/fuxVMRuDdoZXhw6NpYzGKoCk=";
  };
  fa4Python = pkgs.runCommand "thor-fa4-python" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    mkdir -p "$out"
    unzip -q ${fa4Wheel} -d "$out"
    unzip -q ${tvmFfiWheel} -d "$out"
  '';
  prepare = pkgs.writeShellApplication {
    name = "thor-inference-prepare";
    runtimeInputs = with pkgs; [ coreutils docker jq patch ];
    text = builtins.readFile ./inference/prepare.sh;
  };
  memoryGuard = pkgs.writeShellApplication {
    name = "thor-inference-memwatch";
    runtimeInputs = with pkgs; [ coreutils gawk systemd ];
    text = builtins.readFile ./inference/memwatch.sh;
  };
  healthcheck = pkgs.writeShellApplication {
    name = "thor-inference-healthcheck";
    runtimeInputs = with pkgs; [ coreutils curl gawk systemd ];
    text = builtins.readFile ./inference/healthcheck.sh;
  };
  startCondition = pkgs.writeShellScript "thor-inference-start-condition" ''
    test ! -e /run/thor-inference/memory-stop || exit 1
    ${pkgs.gawk}/bin/awk '
      /^MemAvailable:/ { available=$2 }
      /^MemFree:/ { free=$2 }
      END { exit !(available >= 12*1048576 && (free >= 3*1048576 || available >= 18*1048576)) }
    ' /proc/meminfo
  '';
  readyFor = port: pkgs.writeShellScript "thor-inference-ready-${toString port}" ''
    for attempt in $(${pkgs.coreutils}/bin/seq 1 72); do
      if ${pkgs.curl}/bin/curl --silent --fail --connect-timeout 2 --max-time 3 http://127.0.0.1:${toString port}/health >/dev/null; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 5
    done
    exit 1
  '';
  mkRun = { name, port, contextLength, maxRunning, maxTotal, mambaSlots, graphBatch, workState ? state, memoryLimit ? "90g" }:
    pkgs.writeShellScript "${name}-run" ''
      exec ${pkgs.docker}/bin/docker run --rm --name ${name} --pull=never \
        --device=nvidia.com/gpu=all --shm-size=8g --memory=${memoryLimit} --memory-swap=${memoryLimit} \
        --publish=127.0.0.1:${toString port}:8888 \
        --env HF_HOME=/models --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 \
        --env THOR_GDN_VERIFY_BV16=1 \
        --env PYTHONPATH=/opt/fa4-b31 --env SGLANG_INKLING_FA4_USE_PIP=1 \
        --volume ${state}/huggingface:/models:ro \
        --volume ${workState}/kernel-cache:/root/.cache \
        --volume ${workState}/work:/work \
        --volume ${fa4Python}:/opt/fa4-b31:ro \
        ${lib.concatMapStringsSep " \\\n      " (entry: "--volume ${workState}/runtime-patches/${entry.file}:${entry.source}:ro") manifest} \
        --volume ${./inference/thor_dflash_int8_head.py}:/opt/sglang/lib/python3.12/site-packages/thor_dflash_int8_head.py:ro \
        ${image} python3 -m sglang.launch_server \
        --model-path /models/${target} --served-model-name qwen3.8-27b-thor \
        --quantization modelopt_fp4 \
        --context-length ${toString contextLength} --max-running-requests ${toString maxRunning} --max-total-tokens ${toString maxTotal} \
        --page-size 128 \
        --mem-fraction-static 0.65 --chunked-prefill-size 1024 --prefill-decode-interval 1 \
        --attention-backend triton \
        --prefill-attention-backend fa4 --decode-attention-backend triton \
        --speculative-draft-attention-backend triton \
        --linear-attn-backend triton --linear-attn-prefill-backend triton \
        --linear-attn-decode-backend triton --linear-attn-verify-backend triton \
        --kv-cache-dtype bfloat16 --fp4-gemm-backend flashinfer_cutlass \
        --mamba-ssm-dtype bfloat16 --max-mamba-cache-size ${toString mambaSlots} \
        --cuda-graph-backend-decode full --cuda-graph-max-bs-decode ${toString graphBatch} \
        --cuda-graph-backend-prefill disabled \
        --speculative-algorithm DFLASH --speculative-num-draft-tokens 16 \
        --speculative-draft-model-path /models/${draft} \
        --speculative-draft-model-quantization modelopt_fp4 --mamba-radix-cache-strategy extra_buffer \
        --reasoning-parser qwen3 --tool-call-parser qwen3_coder --host 0.0.0.0 --port 8888
    '';
in
{
  systemd.services.thor-inference = {
    description = "Thor Qwen3.8-27B DFlash2 inference";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" "thor-inference-memwatch.service" ];
    after = [ "docker.service" "thor-inference-memwatch.service" ];
    unitConfig = {
      StartLimitIntervalSec = 900;
      StartLimitBurst = 3;
    };
    path = [ pkgs.docker pkgs.coreutils ];
    preStart = ''
      test -f ${state}/huggingface/${target}/model.safetensors.index.json
      test -f ${state}/huggingface/${draft}/config.json
      mkdir -p ${state}/kernel-cache ${state}/work
      ${prepare}/bin/thor-inference-prepare ${image} ${patches} ${state}/runtime-patches
      rm -f /run/thor-inference/health-failures
      if docker container inspect thor-inference >/dev/null 2>&1; then
        docker stop --time 45 thor-inference >/dev/null || true
        docker rm thor-inference >/dev/null 2>&1 || true
      fi
    '';
    serviceConfig = {
      ExecCondition = startCondition;
      ExecStart = mkRun {
        name = "thor-inference";
        port = 8888;
        contextLength = 262144;
        maxRunning = 4;
        maxTotal = 270336;
        mambaSlots = 24;
        graphBatch = 4;
      };
      ExecStartPost = readyFor 8888;
      ExecStop = "-${pkgs.docker}/bin/docker stop --time 45 thor-inference";
      Restart = "always";
      RestartSec = 30;
      TimeoutStartSec = 600;
      TimeoutStopSec = 60;
      StateDirectory = "thor-inference";
      StateDirectoryMode = "0755";
    };
  };

  systemd.services.thor-inference-memwatch = {
    description = "Thor inference memory stop guard";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${memoryGuard}/bin/thor-inference-memwatch";
      Restart = "always";
      RestartSec = 1;
      RuntimeDirectory = "thor-inference";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
    };
  };

  systemd.services.thor-inference-healthcheck = {
    description = "Recover an unresponsive Thor inference server";
    after = [ "thor-inference-memwatch.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${healthcheck}/bin/thor-inference-healthcheck";
      TimeoutStartSec = 90;
    };
  };
  systemd.timers.thor-inference-healthcheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitInactiveSec = "30s";
      AccuracySec = "1s";
    };
  };

  systemd.services.thor-inference-experiment = {
    description = "On-demand Thor inference experiment";
    requires = [ "docker.service" "thor-inference-experiment-memwatch.service" ];
    after = [ "docker.service" "thor-inference-experiment-memwatch.service" ];
    path = [ pkgs.docker pkgs.coreutils ];
    preStart = ''
      mkdir -p ${state}/experiment/kernel-cache ${state}/experiment/work
      ${prepare}/bin/thor-inference-prepare ${image} ${patches} ${state}/experiment/runtime-patches
      if docker container inspect thor-inference-experiment >/dev/null 2>&1; then
        docker stop --time 15 thor-inference-experiment >/dev/null || true
        docker rm thor-inference-experiment >/dev/null 2>&1 || true
      fi
    '';
    serviceConfig = {
      ExecCondition = pkgs.writeShellScript "thor-experiment-start-condition" ''
        ${pkgs.gawk}/bin/awk '/^MemAvailable:/ { exit !($2 >= 48*1048576) }' /proc/meminfo
      '';
      ExecStart = mkRun {
        name = "thor-inference-experiment";
        port = 8890;
        contextLength = 4096;
        maxRunning = 1;
        maxTotal = 8192;
        mambaSlots = 8;
        graphBatch = 1;
        workState = "${state}/experiment";
        memoryLimit = "48g";
      };
      ExecStartPost = readyFor 8890;
      ExecStop = "-${pkgs.docker}/bin/docker stop --time 15 thor-inference-experiment";
      ExecStopPost = "-${pkgs.docker}/bin/docker rm --force thor-inference-experiment";
      Restart = "no";
      TimeoutStartSec = 600;
      TimeoutStopSec = 30;
      RuntimeMaxSec = 3600;
    };
  };

  systemd.services.thor-inference-experiment-memwatch = {
    description = "Stop Thor experiment before production memory guard";
    partOf = [ "thor-inference-experiment.service" ];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "thor-experiment-memwatch" ''
        while ${pkgs.coreutils}/bin/sleep 1; do
          status=$(${pkgs.systemd}/bin/systemctl show --property=ActiveState --value thor-inference-experiment.service)
          case "$status" in inactive|failed) exit 0 ;; esac
          if ! ${pkgs.gawk}/bin/awk '
            /^MemAvailable:/ { a=$2 }
            /^MemFree:/ { f=$2 }
            END { exit !(a >= 18*1048576 && (f >= 4*1048576 || a >= 22*1048576)) }
          ' /proc/meminfo; then
            echo "Stopping experiment to preserve production memory headroom"
            ${pkgs.docker}/bin/docker kill thor-inference-experiment >/dev/null 2>&1 || true
            ${pkgs.systemd}/bin/systemctl stop --no-block thor-inference-experiment.service
            exit 0
          fi
        done
      '';
      Restart = "no";
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8889 ];
  systemd.sockets.thor-inference-proxy = {
    description = "Thor inference backend on Tailscale only";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "100.88.133.23:8889" ];
    socketConfig = {
      FreeBind = true;
      NoDelay = true;
    };
  };
  systemd.services.thor-inference-proxy = {
    description = "Forward the Tailscale backend to loopback inference";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:8888";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };
}
