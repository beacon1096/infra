"""Attest the running thor-inference (Qwen3.8-27B DFlash2) service against a
declared benchmark profile (default `P`) and emit a runtime record the benchmark
client can verify.

Usage: record-thor-27b-runtime.py PROFILES.json OUTPUT_DIR [PROFILE_ID]
"""

import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

BASE = "http://127.0.0.1:8888"
CONTAINER = "thor-inference"
UNIT = "thor-inference.service"
TARGET_DIR = "/var/lib/thor-inference/huggingface/lazycat-qwen38-target-e5ff498"
CONTAINER_MEMORY_LIMIT = "90g"


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as response:
        return json.load(response)


def main(argv):
    profiles_file, output_dir = Path(argv[1]), Path(argv[2])
    profile_id = argv[3] if len(argv) > 3 else "P"
    profile = next(item for item in json.loads(profiles_file.read_text())["profiles"] if item["id"] == profile_id)

    invocation = command("systemctl", "show", UNIT, "--value", "-p", "InvocationID")
    if command("systemctl", "is-active", UNIT) != "active":
        raise RuntimeError("thor-inference service is not active")
    info = api("/get_server_info")
    image = command("docker", "container", "inspect", CONTAINER, "--format", "{{.Image}}")
    revision = command("docker", "image", "inspect", image, "--format",
                       '{{index .Config.Labels "org.opencontainers.image.revision"}}')
    versions = json.loads(command("docker", "exec", "-e", "PYTHONPATH=/opt/fa4-b31", CONTAINER, "python3", "-c",
                                  'import importlib.metadata,json; print(json.dumps({n:importlib.metadata.version(n) for n in ["flash-attn-4"]}))'))
    config = json.loads((Path(TARGET_DIR) / "config.json").read_text())
    quantized = config.get("quantization_config", {}).get("quantized_layers", {})
    head_dtype = "bfloat16" if "lm_head" not in quantized else "quantized"

    settings = {
        "target_quantization": info["quantization"],
        "draft_quantization": info["speculative_draft_model_quantization"],
        "speculative_algorithm": info["speculative_algorithm"],
        "speculative_num_draft_tokens": info["speculative_num_draft_tokens"],
        "kv_cache_dtype": info["kv_cache_dtype"],
        "mamba_ssm_dtype": info["mamba_ssm_dtype"],
        "target_head_dtype": head_dtype,
        "prefill_attention_backend": info["prefill_attention_backend"],
        "flash_attn_version": versions["flash-attn-4"],
        "decode_attention_backend": info["decode_attention_backend"],
        "draft_attention_backend": info["speculative_draft_attention_backend"],
        "linear_attention_backend": info["linear_attn_backend"],
        "fp4_gemm_backend": info["fp4_gemm_runner_backend"],
        "context_length": info["context_length"],
        "max_total_tokens": info["max_total_num_tokens"],
        "max_running_requests": info["max_running_requests"],
        "max_mamba_cache_size": info["max_mamba_cache_size"],
        "page_size": info["page_size"],
        "chunked_prefill_size": info["chunked_prefill_size"],
        "prefill_decode_interval": info["prefill_decode_interval"],
        "mem_fraction_static": info["mem_fraction_static"],
        "container_memory_limit": CONTAINER_MEMORY_LIMIT,
        "cuda_graph_backend_decode": info["cuda_graph_backend_decode"],
        "cuda_graph_max_bs_decode": info["cuda_graph_max_bs_decode"],
        "cuda_graph_backend_prefill": info["cuda_graph_backend_prefill"],
        "mamba_radix_cache_strategy": info["mamba_radix_cache_strategy"],
        "reasoning_parser": info["reasoning_parser"],
        "tool_call_parser": info["tool_call_parser"],
        "prefix_caching": not info["disable_radix_cache"],
    }
    if invocation != command("systemctl", "show", UNIT, "--value", "-p", "InvocationID"):
        raise RuntimeError("service restarted while collecting evidence")
    evidence = {"observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "invocation": invocation, "image_id": image, "engine_revision": revision,
                "server_version": info["version"], "observed_settings": settings,
                "model_config_sha256": hashlib.sha256((Path(TARGET_DIR) / "config.json").read_bytes()).hexdigest()}
    evidence_data = (json.dumps(evidence, sort_keys=True, indent=2) + "\n").encode()
    pins = dict(profile["pins"], image_id=image, engine_revision=revision)
    record = {"profile_id": profile_id, "observed_at": evidence["observed_at"],
              "evidence_sha256": hashlib.sha256(evidence_data).hexdigest(), "pins": pins, "settings": settings}
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, data in (("evidence.json", evidence_data), ("runtime.json", (json.dumps(record, indent=2) + "\n").encode())):
        path = output_dir / name
        path.write_bytes(data)
        path.chmod(0o600)
    print(json.dumps({"profile": profile_id, "record": str(output_dir / "runtime.json"),
                      "evidence_sha256": record["evidence_sha256"], "settings": settings}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
