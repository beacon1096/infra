"""Compare two teacher-forced prefill captures (see run-thor-prefill-drift.py).

Usage: compare-thor-prefill-drift.py A.json B.json

Reports, over positions present in both: mean/max |logprob delta|, top-1 change
rate, mean top-10 overlap, and a 512-token binned breakdown so divergence tied
to state checkpoint boundaries (e.g. chunked-prefill-size) is visible.
"""

import json
import statistics
import sys


def top1(row):
    return row[0][1] if row else None


def id_set(row):
    return {entry[1] for entry in row} if row else set()


def compare(a, b, label):
    lp_a, lp_b = a["logprobs"], b["logprobs"]
    t_a, t_b = a["top_logprobs"], b["top_logprobs"]
    idx = [i for i in range(len(lp_a)) if lp_a[i] is not None and lp_b[i] is not None]
    delta = [abs(lp_b[i] - lp_a[i]) for i in idx]
    top1_changed = sum(1 for i in idx if top1(t_a[i]) != top1(t_b[i]))
    overlap = [len(id_set(t_a[i]) & id_set(t_b[i])) / max(1, len(id_set(t_a[i]) | id_set(t_b[i])))
               for i in idx if t_a[i] and t_b[i]]
    print(f"{label}: n={len(idx)} mean|d|={statistics.mean(delta):.6g} max|d|={max(delta):.6g} "
          f"top1_changed={top1_changed}/{len(idx)} ({100 * top1_changed / len(idx):.2f}%) "
          f"top10_overlap={statistics.mean(overlap):.4f}")
    bins = []
    for start in range(0, len(lp_a), 512):
        sub = [i for i in idx if start <= i < start + 512]
        if not sub:
            continue
        changed = sum(1 for i in sub if top1(t_a[i]) != top1(t_b[i]))
        bins.append(f"{start}: mean={statistics.mean(abs(lp_b[i] - lp_a[i]) for i in sub):.4g} top1={changed}")
    print("  bins " + " | ".join(bins))


def main(argv):
    a = json.load(open(argv[1]))
    b = json.load(open(argv[2]))
    if a["token_ids"] != b["token_ids"]:
        raise SystemExit("token streams differ")
    compare(a, b, argv[3] if len(argv) > 3 else "A vs B")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
