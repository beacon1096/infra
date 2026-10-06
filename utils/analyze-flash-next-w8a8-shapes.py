#!/usr/bin/env python3
"""Aggregate the W8A8 dense-FP8 shape log written by the patched
`w8a8_block_fp8_matmul_triton` (env SGLANG_W8A8_SHAPE_LOG).

Input: a log file with one `M=..,N=..,K=..,BM=..,BN=..,BK=..,warps=..,stages=..`
line per kernel launch. Prints the distinct shapes ordered by call count.

Usage: analyze-flash-next-w8a8-shapes.py SHAPES.log
"""

import collections
import sys


def main(argv):
    if len(argv) != 2:
        print(__doc__ % {}, file=sys.stderr)
        return 2
    counts = collections.Counter()
    with open(argv[1]) as handle:
        for line in handle:
            line = line.strip()
            if line:
                counts[line] += 1
    print("total calls", sum(counts.values()), "distinct shapes", len(counts))
    for line, count in counts.most_common():
        print("%6d  %s" % (count, line))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
