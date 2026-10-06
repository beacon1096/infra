"""Compare two GDN state-dump directories produced by run-thor-prefill-drift.py.

Usage: compare-gdn-state-dump.py DIR_A DIR_B [SEQ]

Each directory holds layerNNN_seqNNNNNN.npy files written by the diagnostic
gdn_backend.py overlay (SGLANG_GDN_STATE_DUMP). Without SEQ, prints per-seq
mean/max relative L2 and min cosine over layers. With SEQ, prints per-layer
relative L2 / cosine / state norm for that boundary.

Run with numpy available (e.g. inside the pinned SGLang image), because it
reads .npy state tensors.
"""

import glob
import os
import sys

import numpy as np


def load_dir(directory, seq=None):
    if seq is None:
        files = {}
        for path in glob.glob(os.path.join(directory, "layer*_seq*.npy")):
            base = os.path.basename(path)[:-4]
            layer, seq_tag = base.split("_")
            files[(layer, int(seq_tag[3:]))] = path
        return files
    files = {}
    for path in glob.glob(os.path.join(directory, "layer*_seq%06d.npy" % seq)):
        files[int(os.path.basename(path)[5:8])] = path
    return files


def stats(x, y):
    rel = np.linalg.norm(x - y) / (np.linalg.norm(x) + 1e-12)
    cos = float(np.dot(x, y) / (np.linalg.norm(x) * np.linalg.norm(y) + 1e-30))
    return float(rel), cos


def main(argv):
    a_dir, b_dir = argv[1], argv[2]
    if len(argv) > 3:
        seq = int(argv[3])
        a, b = load_dir(a_dir, seq), load_dir(b_dir, seq)
        for layer in sorted(set(a) & set(b)):
            x = np.load(a[layer]).astype(np.float64).ravel()
            y = np.load(b[layer]).astype(np.float64).ravel()
            rel, cos = stats(x, y)
            print("L%03d |x|=%.3f relL2=%.4f cos=%.5f" % (layer, np.linalg.norm(x), rel, cos))
        return 0
    a, b = load_dir(a_dir), load_dir(b_dir)
    per_seq = {}
    for key in sorted(set(a) & set(b)):
        x = np.load(a[key]).astype(np.float64).ravel()
        y = np.load(b[key]).astype(np.float64).ravel()
        per_seq.setdefault(key[1], []).append(stats(x, y))
    for seq in sorted(per_seq):
        rows = per_seq[seq]
        rels = [rel for rel, _ in rows]
        coss = [cos for _, cos in rows]
        print("seq=%6d n=%2d mean_relL2=%.3e max_relL2=%.3e min_cos=%.9f"
              % (seq, len(rows), np.mean(rels), max(rels), min(coss)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
