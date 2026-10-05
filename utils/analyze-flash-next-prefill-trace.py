#!/usr/bin/env python3
"""Break a SGLang torch-profiler chrome trace into kernel-time buckets.

Reads a gzipped/plain chrome trace and reports corrected categories, the grouped
CUTLASS MoE GEMM(s) by full name, the dense FP8 `_w8a8_block_fp8_matmul` by
launch grid (shape proxy), and the TensorRT-LLM CUTLASS MoE auxiliary kernels.

Note: a naive name->category mapping mis-buckets the MoE auxiliary kernels
(`tensorrt_llm::...cutlass_kernels::expandInputRowsKernel<...__nv_fp4_e2m1...>`),
whose names contain both `cutlass` and `fp4`; this classifier checks the
TensorRT-LLM MoE kernels before the generic gemm/fp4 buckets. Kernel events carry
grid/block but not input dims, so the grid is used as a shape proxy.

Usage: analyze-flash-next-prefill-trace.py TRACE.json[.gz]
"""

import collections
import gzip
import json
import sys


def load(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as handle:
        obj = json.load(handle)
    return obj.get("traceEvents", []) if isinstance(obj, dict) else obj


def category(name):
    lower = name.lower()
    if "groupproblemshape" in lower:
        return "moe-grouped-gemm"
    if "tensorrt_llm" in lower and "cutlass_kernels" in lower:
        return "moe-aux"
    if "_w8a8_block_fp8_matmul" in lower:
        return "dense-fp8"
    if "nvjet" in lower or "cublas" in lower:
        return "cublas"
    if "topk" in lower or "indexer" in lower or "qsa" in lower:
        return "qsa"
    if "_sparse_gqa" in lower or "flash" in lower or "fmha" in lower:
        return "attn"
    if any(key in lower for key in ("gated_delta", "chunk_fwd", "recompute_w_u", "causal_conv1d", "gdn", "mamba")):
        return "gdn"
    if "hc_combine" in lower or "hyper" in lower:
        return "hyperconn"
    if "rmsnorm" in lower or "layer_norm" in lower or "norm" in lower:
        return "norm"
    if any(key in lower for key in ("silu", "sigmoid", "activation", "softmax")):
        return "act"
    if any(key in lower for key in ("embedding", "ple", "gather", "index_select")):
        return "ple"
    if "memcpy" in lower or "memset" in lower:
        return "mem"
    if "nccl" in lower:
        return "nccl"
    if any(key in lower for key in ("elementwise", "direct_copy", "copy", "cat")):
        return "elementwise"
    if "cutlass" in lower or "gemm" in lower or "mma" in lower:
        return "gemm-other"
    return "other"


def main(argv):
    if len(argv) != 2:
        print(__doc__ % {}, file=sys.stderr)
        return 2
    events = load(argv[1])
    by_category = collections.Counter()
    grouped = collections.Counter()
    dense = collections.Counter()
    dense_count = collections.Counter()
    moe_aux = collections.Counter()
    total = 0.0
    for event in events:
        if event.get("cat") != "kernel":
            continue
        name = event.get("name", "")
        duration = event.get("dur", 0) or 0
        total += duration
        by_category[category(name)] += duration
        if "GemmUniversal" in name and "GroupProblemShape" in name:
            grouped[name] += duration
        elif "_w8a8_block_fp8_matmul" in name:
            grid = tuple(event.get("args", {}).get("grid", []) or [])
            dense[grid] += duration
            dense_count[grid] += 1
        elif "tensorrt_llm" in name and "cutlass_kernels" in name:
            moe_aux[name] += duration
    print("kernel total ms", round(total / 1000, 1))
    print("== corrected category shares ==")
    for key, duration in by_category.most_common():
        print("%-18s %8.1f ms  %5.1f%%" % (key, duration / 1000, 100 * duration / total))
    print("== grouped CUTLASS MoE GEMM by full name ==")
    for name, duration in grouped.most_common():
        print("%8.1f ms  %s" % (duration / 1000, name))
    print("== dense FP8 _w8a8_block_fp8_matmul by grid ==")
    for grid, duration in dense.most_common():
        print("%8.1f ms  count=%4d  grid=%s" % (duration / 1000, dense_count[grid], list(grid)))
    print("== TensorRT-LLM CUTLASS MoE auxiliary kernels ==")
    for name, duration in moe_aux.most_common():
        print("%8.1f ms  %s" % (duration / 1000, name[:110]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
