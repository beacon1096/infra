#!/usr/bin/env python3
"""Break a SGLang torch-profiler chrome trace into kernel-time buckets.

Reads a gzipped/plain chrome trace and reports: the grouped CUTLASS MoE GEMM(s)
by full kernel name, the dense FP8 `_w8a8_block_fp8_matmul` by launch grid
(shape proxy), and the TensorRT-LLM CUTLASS MoE auxiliary kernels. Kernel events
carry grid/block but not input dims, so the grid is used as a shape proxy.

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


def main(argv):
    if len(argv) != 2:
        print(__doc__ % {}, file=sys.stderr)
        return 2
    events = load(argv[1])
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
        if "GemmUniversal" in name and "GroupProblemShape" in name:
            grouped[name] += duration
        elif "_w8a8_block_fp8_matmul" in name:
            grid = tuple(event.get("args", {}).get("grid", []) or [])
            dense[grid] += duration
            dense_count[grid] += 1
        elif "tensorrt_llm" in name and "cutlass_kernels" in name:
            moe_aux[name] += duration
    print("kernel total ms", round(total / 1000, 1))
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
