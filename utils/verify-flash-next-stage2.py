"""Static verification of a Stage-2 mixed artifact built by build-flash-next-stage2.py.

Usage: verify-flash-next-stage2.py MODEL_DIR [--expect-targets N]

Checks the quant config is modelopt_mixed/MIXED_PRECISION, the index tensor
count and number of weight_scale_inv tensors match the production FP8_PB_WO
targets, PLE dtype, and sample dense/head dtypes. Run with safetensors+torch
available (e.g. inside the pinned SGLang image).
"""

import collections
import json
import os
import sys

from safetensors import safe_open


def main(argv):
    d = argv[1]
    expect = None
    if "--expect-targets" in argv:
        expect = int(argv[argv.index("--expect-targets") + 1])
    cfg = json.load(open(os.path.join(d, "config.json")))
    q = cfg.get("quantization_config", {})
    cats = collections.Counter((v.get("quant_algo"), v.get("group_size")) for v in q.get("quantized_layers", {}).values())
    print("quant:", q.get("quant_method"), q.get("quant_algo"), dict(cats))
    idx = json.load(open(os.path.join(d, "model.safetensors.index.json")))["weight_map"]
    n_scale = sum(1 for k in idx if k.endswith("weight_scale_inv"))
    print("index tensors:", len(idx), "| weight_scale_inv:", n_scale,
          "| ple_embedding_dtype:", cfg.get("text_config", {}).get("ple_embedding_dtype"))
    if expect is not None:
        print("targets match:", n_scale == expect, f"(expected {expect})")

    def show(file, key):
        with safe_open(os.path.join(d, file), framework="pt") as f:
            if key in f.keys():
                sl = f.get_slice(key)
                print(f"  {key} -> {sl.get_dtype()} {tuple(sl.get_shape())}")
            else:
                print(f"  {key} -> ABSENT")

    show("model-bf16-00012.safetensors", "lm_head.weight")
    show("model-bf16-00012.safetensors", "lm_head.weight_scale_inv")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
