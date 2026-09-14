#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
flashinfer_root=/opt/sglang/lib/python3.12/site-packages/flashinfer
/usr/local/cuda/bin/nvcc -std=c++17 -O3 -DNDEBUG -DENABLE_BF16 \
  -gencode arch=compute_110a,code=sm_110a --expt-relaxed-constexpr --expt-extended-lambda \
  -I"$flashinfer_root/data/include" -I"$flashinfer_root/data/cutlass/include" \
  -I"$flashinfer_root/data/cutlass/tools/util/include" \
  "$source_dir/native-probe.cu" -o "$source_dir/native-probe"
