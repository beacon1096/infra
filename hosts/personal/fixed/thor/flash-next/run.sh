#!/usr/bin/env bash
set -euo pipefail

container=thor-flash-next
: "${RUNTIME_DIR:?Set RUNTIME_DIR to the unit runtime directory}"
: "${INVOCATION_ID:?Run through the managed systemd unit}"
[[ "$INVOCATION_ID" =~ ^[0-9a-f]{32}$ ]]
cid_file="$RUNTIME_DIR/container-$INVOCATION_ID.cid"
case "${1:-run}" in
    cleanup)
        if [[ -f "$cid_file" ]]; then
            cid=$(< "$cid_file")
            [[ "$cid" =~ ^[0-9a-f]{64}$ ]]
            if docker container inspect "$cid" >/dev/null 2>&1; then
                docker stop --time 15 "$cid" || true
                docker rm --force "$cid" >/dev/null 2>&1 || true
            fi
            rm -f "$cid_file"
        fi
        exit 0
        ;;
    run) ;;
    *) printf 'Usage: %s [run|cleanup]\n' "$0" >&2; exit 2 ;;
esac

: "${BASELINE_FILE:=$(dirname "${BASH_SOURCE[0]}")/baseline.json}"
: "${IMAGE:?Set IMAGE to the pinned public image}"
: "${MODEL_DIR:?Set MODEL_DIR to the verified checkpoint directory}"
: "${CACHE_DIR:?Set CACHE_DIR to the revision-isolated writable cache}"
: "${FA4_LAYER:?Set FA4_LAYER to the isolated FA4 layer}"
: "${PREPARE_PROGRAM:?Set PREPARE_PROGRAM to the hash-checked patch preparer}"
: "${PATCH_DIR:?Set PATCH_DIR to the immutable patch inputs}"
: "${DRAFT_DIR:=}"
: "${OPTIMIZATION_DIR:=}"
: "${W8A8_SHAPE_LOG:=}"
: "${GDN_STATE_DUMP:=}"
: "${GDN_STATE_DUMP_LAYERS:=}"

test -d "$RUNTIME_DIR"
test ! -e "$RUNTIME_DIR/memory-stop"
jq -e --arg image "$IMAGE" --arg model "$MODEL_DIR" '
    .image == $image and .model_dir == $model and
    (.arguments | type == "array" and length > 0 and all(.[]; type == "string"))
' "$BASELINE_FILE" >/dev/null
docker image inspect "$IMAGE" --format '{{json .}}' |
    jq -e '.Architecture == "arm64" and .Os == "linux"' >/dev/null
jq -e --slurpfile baseline "$BASELINE_FILE" '
    .phase == "verified" and
    .verified_files == $baseline[0].prepared_observation.files and
    .total_files == $baseline[0].prepared_observation.files and
    .total_bytes == $baseline[0].prepared_observation.bytes and
    .copied_bytes == $baseline[0].prepared_observation.bytes and
    .pins.target.revision == $baseline[0].target_revision and
    .pins.configuration_draft_optimization.revision == $baseline[0].configuration_revision
' "$MODEL_DIR/prepared.json" >/dev/null
jq -e '.quantization_config.quant_method == "modelopt_mixed"' "$MODEL_DIR/target/config.json" >/dev/null
test -f "$MODEL_DIR/target/hf_quant_config.json"
test -f "$MODEL_DIR/target/model.safetensors.index.json"
test -d "$MODEL_DIR/draft"
test -d "$MODEL_DIR/optimization"
test -d "$FA4_LAYER/flash_attn"

if ! awk '/^MemAvailable:/ { found=1; available=$2 }
    END { exit !(found && available >= 100*1048576) }' /proc/meminfo; then
    printf 'Refusing load: at least 100 GiB MemAvailable is required\n' >&2
    exit 1
fi
if docker container inspect "$container" >/dev/null 2>&1; then
    printf 'Refusing load: container %s already exists; clean it explicitly\n' "$container" >&2
    exit 1
fi
mapfile -t arguments < <(jq -r '.arguments[]' "$BASELINE_FILE")
draft_mount=()
token_mount=()
eagle_mount=()
mtp_requested=false
token_map_requested=false
for argument in "${arguments[@]}"; do
    [[ "$argument" == "--speculative-draft-model-path" ]] && mtp_requested=true
    [[ "$argument" == "--speculative-token-map" ]] && token_map_requested=true
done
if $mtp_requested; then
    if [[ -z "$DRAFT_DIR" ]]; then
        printf 'DRAFT_DIR is required when the baseline enables MTP\n' >&2
        exit 1
    fi
    test -d "$DRAFT_DIR"
    test -f "$DRAFT_DIR/config.json"
    test -f "$DRAFT_DIR/hf_quant_config.json"
    draft_mount=("--mount" "type=bind,src=$DRAFT_DIR,dst=/models/draft,readonly")
fi
if $token_map_requested; then
    if [[ -z "$OPTIMIZATION_DIR" ]]; then
        printf 'OPTIMIZATION_DIR is required when the baseline sets a token map\n' >&2
        exit 1
    fi
    test -d "$OPTIMIZATION_DIR"
    test -f "$OPTIMIZATION_DIR/vocab-32768-corpus.pt"
    token_mount=("--mount" "type=bind,src=$OPTIMIZATION_DIR,dst=/vocab-maps,readonly")
fi
install -d -m 0700 "$CACHE_DIR/ple" "$CACHE_DIR/kernel-cache"
"$PREPARE_PROGRAM" "$IMAGE" "$PATCH_DIR" "$CACHE_DIR/runtime-patches"
if $token_map_requested; then
    test -f "$CACHE_DIR/runtime-patches/eagle_worker_v2.py"
    eagle_mount=("--mount" "type=bind,src=$CACHE_DIR/runtime-patches/eagle_worker_v2.py,dst=/sgl-workspace/sglang/python/sglang/srt/speculative/eagle_worker_v2.py,readonly")
fi
shape_env=()
shape_mount=()
if [[ -n "$W8A8_SHAPE_LOG" ]]; then
    test -f "$CACHE_DIR/runtime-patches/fp8_kernel.py"
    shape_env=("--env" "SGLANG_W8A8_SHAPE_LOG=$W8A8_SHAPE_LOG")
    shape_mount=("--mount" "type=bind,src=$CACHE_DIR/runtime-patches/fp8_kernel.py,dst=/sgl-workspace/sglang/python/sglang/kernels/ops/quantization/fp8_kernel.py,readonly")
fi
gdn_env=()
gdn_mount=()
if [[ -n "$GDN_STATE_DUMP" ]]; then
    test -f "$CACHE_DIR/runtime-patches/gdn_backend.py"
    install -d -m 0755 "$GDN_STATE_DUMP"
    gdn_env=("--env" "SGLANG_GDN_STATE_DUMP=/gdn-state")
    if [[ -n "$GDN_STATE_DUMP_LAYERS" ]]; then
        gdn_env+=("--env" "SGLANG_GDN_STATE_DUMP_LAYERS=$GDN_STATE_DUMP_LAYERS")
    fi
    gdn_mount=(
        "--mount" "type=bind,src=$GDN_STATE_DUMP,dst=/gdn-state"
        "--mount" "type=bind,src=$CACHE_DIR/runtime-patches/gdn_backend.py,dst=/sgl-workspace/sglang/python/sglang/srt/layers/attention/linear/gdn_backend.py,readonly"
    )
fi
printf 'Starting mixed-target-only baseline; BF16 dtype does not undo mixed/FP8 weights\n'

exec docker run --rm --name "$container" --pull=never \
    "${draft_mount[@]}" \
    "${token_mount[@]}" \
    "${eagle_mount[@]}" \
    "${shape_mount[@]}" \
    "${gdn_mount[@]}" \
    --cidfile="$cid_file" \
    --device=nvidia.com/gpu=all --shm-size=8g --memory=108g --memory-swap=108g \
    --publish=127.0.0.1:8890:8890 \
    "${shape_env[@]}" \
    "${gdn_env[@]}" \
    --env HF_HOME=/root/.cache/huggingface --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 \
    --env PYTHONPATH=/opt/owned-fa4 --env SGLANG_INKLING_FA4_USE_PIP=1 \
    --env SGLANG_QWEN4_PLE_FILE_RSS_BUDGET_GB=4 \
    --mount "type=bind,src=$MODEL_DIR/target,dst=/models/target,readonly" \
    --mount "type=bind,src=$CACHE_DIR/ple,dst=/ple" \
    --mount "type=bind,src=$CACHE_DIR/kernel-cache,dst=/root/.cache" \
    --mount "type=bind,src=$FA4_LAYER,dst=/opt/owned-fa4,readonly" \
    --mount "type=bind,src=$CACHE_DIR/runtime-patches/vocab_parallel_embedding.py,dst=/sgl-workspace/sglang/python/sglang/srt/layers/vocab_parallel_embedding.py,readonly" \
    "$IMAGE" python3 -m sglang.launch_server "${arguments[@]}"
