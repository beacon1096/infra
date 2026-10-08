import json
import sys

import torch
from sglang.kernels.ops.quantization import fp8_kernel as fk

M = 2048
SHAPES = [(2560, 6144), (2560, 640), (1280, 2560), (16384, 2560), (13312, 2560)]
FP8_MAX = 448.0
BLOCK = [128, 128]


def cfg(bm, bn, bk, g, w, s):
    return {"BLOCK_SIZE_M": bm, "BLOCK_SIZE_N": bn, "BLOCK_SIZE_K": bk,
            "GROUP_SIZE_M": g, "num_warps": w, "num_stages": s}


CANDS = [
    cfg(64, 128, 128, 32, 4, 3),   # default
    cfg(64, 128, 128, 8, 4, 3),
    cfg(64, 256, 128, 8, 4, 3),
    cfg(128, 128, 128, 8, 4, 3),
    cfg(128, 256, 128, 8, 8, 3),
    cfg(256, 128, 128, 8, 8, 3),
    cfg(128, 128, 256, 8, 4, 3),
    cfg(128, 64, 128, 8, 4, 3),
    cfg(256, 256, 128, 8, 8, 3),
    cfg(64, 128, 128, 1, 4, 4),
]


def make(N, K):
    A = ((torch.rand(M, K, device="cuda") - 0.5) * 2 * FP8_MAX).clamp(-FP8_MAX, FP8_MAX).to(torch.float8_e4m3fn)
    B = ((torch.rand(N, K, device="cuda") - 0.5) * 2 * FP8_MAX).clamp(-FP8_MAX, FP8_MAX).to(torch.float8_e4m3fn)
    n_tiles, k_tiles = (N + 127) // 128, (K + 127) // 128
    As = torch.rand(M, k_tiles, device="cuda") * 1e-2
    Bs = torch.rand(n_tiles, k_tiles, device="cuda") * 1e-2
    return A, B, As, Bs


def run(A, B, As, Bs):
    return fk.w8a8_block_fp8_matmul_triton(A, B, As, Bs, BLOCK, torch.bfloat16)


def bench(A, B, As, Bs, iters=30):
    for _ in range(5):
        run(A, B, As, Bs)
    torch.cuda.synchronize()
    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    times = []
    for _ in range(iters):
        torch.cuda.synchronize()
        start.record()
        run(A, B, As, Bs)
        end.record()
        end.synchronize()
        times.append(start.elapsed_time(end) * 1000.0)
    return min(times), sorted(times)[len(times) // 2]


def main():
    report = {}
    for (N, K) in SHAPES:
        A, B, As, Bs = make(N, K)
        fk.get_w8a8_block_fp8_configs = lambda *a, **k: None
        ref = run(A, B, As, Bs)
        rows = []
        for cand in CANDS:
            fk.get_w8a8_block_fp8_configs = lambda *a, _c=cand, **k: {M: _c}
            try:
                out = run(A, B, As, Bs)
                diff = (out.float() - ref.float()).abs().max().item()
                mn, med = bench(A, B, As, Bs)
                rows.append({"config": cand, "min_us": round(mn, 1), "med_us": round(med, 1),
                             "max_abs_diff": round(diff, 4)})
            except Exception as error:  # noqa: BLE001
                rows.append({"config": cand, "error": type(error).__name__})
        rows.sort(key=lambda r: r.get("min_us", 1e9))
        report[f"N={N},K={K}"] = rows
        print(f"N={N},K={K}", flush=True)
        for r in rows:
            print("   ", json.dumps(r), flush=True)
    with open("/tmp/w8a8-tune-out.json", "w") as handle:
        json.dump(report, handle, indent=2)


if __name__ == "__main__":
    main()
