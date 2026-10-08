"""Build a production-matched modelopt_mixed artifact from the jpezzulli
NVFP4-experts uncensored checkpoint (path B).

Keeps jpezzulli's NVFP4 routed experts, FP8 PLE and BF16 everything-else, and
mechanically quantizes the production FP8_PB_WO set (self_attn q/k/v/o,
linear_attn in_proj_qkv/in_proj_z/out_proj, mlp.shared_expert gate/up/down,
lm_head) from BF16 to FP8 block[128,128]: weight F8_E4M3 + weight_scale_inv
F32 = block_amax/448. Also rewrites the quant config to MIXED_PRECISION.

Usage: build-stage2.py INPUT_DIR OUTPUT_DIR PROD_QUANT_JSON [--dry-run]
"""

import json
import os
import shutil
import sys

import torch
from safetensors import safe_open
from safetensors.torch import load_file, save_file

FP8_MAX = 448.0
BLOCK = 128


def hardlink_tree(src, dst):
    if not os.path.exists(dst):
        os.makedirs(dst)
    for name in os.listdir(src):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(s):
            hardlink_tree(s, d)
        elif not os.path.exists(d):
            os.link(s, d)


def quantize_block_fp8(w):
    """w: [N,K] float32 -> (fp8 [N,K], scale_inv [ceil(N/128),ceil(K/128)] f32)."""
    N, K = w.shape
    q = torch.empty_like(w, dtype=torch.float8_e4m3fn)
    scale = torch.empty((N + BLOCK - 1) // BLOCK, (K + BLOCK - 1) // BLOCK, dtype=torch.float32)
    for i in range(0, N, BLOCK):
        for j in range(0, K, BLOCK):
            blk = w[i:i + BLOCK, j:j + BLOCK]
            amax = blk.abs().max().item()
            s = amax / FP8_MAX if amax > 0 else 1.0
            scale[i // BLOCK, j // BLOCK] = s
            q[i:i + BLOCK, j:j + BLOCK] = (blk / s).clamp(-FP8_MAX, FP8_MAX).to(torch.float8_e4m3fn)
    return q, scale


def main(argv):
    inp, out, prod_quant_path = argv[1:4]
    dry = "--dry-run" in argv
    prod_quant = json.load(open(prod_quant_path))
    if "quantized_layers" in prod_quant:
        ql = prod_quant["quantized_layers"]
    elif "quantization_config" in prod_quant:
        ql = prod_quant["quantization_config"]["quantized_layers"]
    else:
        ql = prod_quant["quantization"]["quantized_layers"]
    fp8_keys = sorted(k for k, v in ql.items() if v.get("quant_algo") == "FP8_PB_WO")
    targets = {k + ".weight" for k in fp8_keys}
    print("FP8_PB_WO targets:", len(targets))

    index = json.load(open(os.path.join(inp, "model.safetensors.index.json")))
    wm = index["weight_map"]
    shards = sorted({wm[t] for t in targets if t in wm})
    missing = [t for t in targets if t not in wm]
    print("shards to rewrite:", shards, "| missing targets:", len(missing))
    if missing:
        print("  first missing:", missing[:3])
    if dry:
        for sh in shards:
            n = sum(1 for t in targets if wm.get(t) == sh)
            print(f"  {sh}: {n} targets")
        return 0

    if "--no-link" not in argv:
        hardlink_tree(inp, out)

    def write_new(path, obj):
        if os.path.exists(path):
            os.remove(path)  # break hardlink so the input is untouched
        with open(path, "w") as handle:
            json.dump(obj, handle, indent=2)

    for sh in shards:
        src = os.path.join(inp, sh)
        dst = os.path.join(out, sh)
        tensors = load_file(src)
        with safe_open(src, framework="pt", device="cpu") as f:
            metadata = f.metadata()
        count = 0
        for t in [t for t in targets if wm.get(t) == sh]:
            w = tensors[t].to(torch.float32)
            q, s = quantize_block_fp8(w)
            tensors[t] = q
            tensors[t + "_scale_inv"] = s.contiguous()
            count += 1
        os.remove(dst)  # break hardlink
        save_file({k: v.contiguous() for k, v in tensors.items()}, dst, metadata=metadata)
        print("rewrote", sh, "quantized", count)

    # rebuild index weight_map: add *_scale_inv for targets
    for t in targets:
        if t in wm:
            wm[t + "_scale_inv"] = wm[t]
    write_new(os.path.join(out, "model.safetensors.index.json"), index)

    # rewrite quant configs to production MIXED_PRECISION
    cfg = json.load(open(os.path.join(inp, "config.json")))
    cfg["quantization_config"] = {
        "quant_method": "modelopt_mixed",
        "quant_algo": "MIXED_PRECISION",
        "ignore": [],
        "quantized_layers": ql,
    }
    write_new(os.path.join(out, "config.json"), cfg)
    hq = {
        "producer": prod_quant.get("producer", {"name": "modelopt", "version": "0.46.0"}),
        "quantization": {
            "exclude_modules": [],
            "quant_algo": "MIXED_PRECISION",
            "quantized_layers": ql,
        },
    }
    write_new(os.path.join(out, "hf_quant_config.json"), hq)

    manifest = {
        "kind": "thor-stage2-derived-from-jpezzulli",
        "source": "jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4",
        "base_model": "OrcaRouter/Qwen3.8-Flash-Next-Uncensored",
        "recipe": {"experts": "nvfp4_group16 (unchanged)", "dense": "fp8_pb_wo_block128 (newly quantized)",
                   "ple": "float8_e4m3fn (unchanged)", "state": "fp32"},
        "fp8_block": BLOCK, "fp8_scale": "block_amax/448",
        "fp8_targets": len(targets), "fp8_shards": shards,
    }
    json.dump(manifest, open(os.path.join(out, "conversion-manifest.json"), "w"), indent=2)
    print("done ->", out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
