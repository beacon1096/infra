#!/usr/bin/env bash
set -euo pipefail

container=thor-tensorfold
image=sha256:b7d9544e6dfc98050c3fb28d26e3411bfef5410b14c5470324754e92230f5640
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

: "${MODEL_ROOT:?Set MODEL_ROOT to the verified artifact directory}"
: "${CACHE_DIR:?Set CACHE_DIR to the writable runtime cache}"
: "${PARALLEL:=1}"
[[ "$PARALLEL" == 1 || "$PARALLEL" == 8 ]]
test -d "$RUNTIME_DIR"
test ! -e "$RUNTIME_DIR/memory-stop"
docker image inspect "$image" --format '{{json .}}' |
    jq -e --arg image "$image" '.Id == $image and .Architecture == "arm64" and .Os == "linux"' >/dev/null

python3 - "$MODEL_ROOT" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = "2944e64b27a54526eed2d633a0b1e0651ff68ba5e0838d26a467faf140cb40fd"
body = (root / "model-manifest.json").read_bytes()
if hashlib.sha256(body).hexdigest() != expected:
    sys.exit("Model manifest SHA256 mismatch")
manifest = json.loads(body)
marker = json.loads((root / "prepared.json").read_bytes())
required = {
    "phase": "verified",
    "repository": "azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound",
    "revision": "1464274120d36a4d8fcaa934552334a7d83ce0fd",
    "verified_files": 123,
    "total_files": 123,
    "total_bytes": 130836896655,
    "manifest_sha256": expected,
}
if any(marker.get(key) != value for key, value in required.items()):
    sys.exit("Model verification marker does not match the pinned artifact")
if manifest["repository"] != required["repository"] or manifest["revision"] != required["revision"]:
    sys.exit("Model manifest revision mismatch")
model = (root / "model").resolve(strict=True)
files = manifest["files"]
if len(files) != 123 or sum(entry["size"] for entry in files) != required["total_bytes"]:
    sys.exit("Model manifest inventory mismatch")
for entry in files:
    path = (model / entry["path"]).resolve(strict=True)
    if not path.is_relative_to(model) or not path.is_file() or path.stat().st_size != entry["size"]:
        sys.exit(f"Missing or changed model file: {entry['path']}")
PY

if ! awk '/^MemAvailable:/ { found=1; available=$2 }
    END { exit !(found && available >= 100*1048576) }' /proc/meminfo; then
    printf 'Refusing load: at least 100 GiB MemAvailable is required\n' >&2
    exit 1
fi
if docker container inspect "$container" >/dev/null 2>&1; then
    printf 'Refusing load: container %s already exists; clean it explicitly\n' "$container" >&2
    exit 1
fi
install -d -m 0700 "$CACHE_DIR/cache" "$CACHE_DIR/triton" "$CACHE_DIR/nv"

exec docker run --rm --name "$container" --pull=never \
    --cidfile="$cid_file" --init \
    --device=nvidia.com/gpu=all --shm-size=8g --memory=108g --memory-swap=108g \
    --ulimit memlock=-1 --ulimit stack=67108864 \
    --publish=127.0.0.1:8890:8888 \
    --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 \
    --env TENSORFOLD_NO_UPDATE_CHECK=1 \
    --env TENSORFOLD_CUDA_KERNELS=/opt/tensorfold/share/tensorfold/cuda/sm110 \
    --env TENSORFOLD_MEMORY_RESERVE_GIB=10 \
    --env TENSORFOLD_VIDEO_TOKENS=16384 --env TENSORFOLD_VISION_WORKSPACE_MIB=2048 \
    --env TF_FLASHNEXT_DEPTH=15 --env TF_FLASHNEXT_PRODUCT_STREAMS=2 \
    --env TF_FLASHNEXT_PREFILL_TAIL=512 --env TF_FLASHNEXT_YARN=0 \
    --env CUDA_CACHE_PATH=/cache/nv \
    --mount "type=bind,src=$MODEL_ROOT/model,dst=/model,readonly" \
    --mount "type=bind,src=$CACHE_DIR/cache,dst=/cache" \
    --mount "type=bind,src=$CACHE_DIR/triton,dst=/cache/triton" \
    --mount "type=bind,src=$CACHE_DIR/nv,dst=/cache/nv" \
    "$image" tensorfold-native serve /model \
    --host 0.0.0.0 --port 8888 --name Qwen3.8-Flash-Next \
    --parallel "$PARALLEL" --context 262144 --kv-dtype fp8 \
    --max-tokens 32768 --temperature 1.0 --top-p 0.95 --top-k 20 \
    --thinking --vision --vision-max-images 50 --vision-max-videos 4 \
    --vision-image-tokens 16384
