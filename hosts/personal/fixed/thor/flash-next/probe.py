"""Check the owned runtime's native imports and SM110 FA4 calls, without loading weights."""

import ctypes
import hashlib
import importlib.metadata
import json
from pathlib import Path

import torch
import tilelang
from flash_attn.cute import flash_attn_func, flash_attn_varlen_func


versions = {name: importlib.metadata.version(name) for name in
            ("sglang", "torch", "flashinfer-python", "transformers", "flash-attn-4", "apache-tvm-ffi", "tilelang")}
properties = torch.cuda.get_device_properties(0)
driver = ctypes.CDLL("libcuda.so.1")
assert driver.cuInit(0) == 0
attributes = {}
for name, number in (("pageable_memory_access", 88), ("pageable_memory_access_uses_host_page_tables", 100)):
    value = ctypes.c_int()
    result = driver.cuDeviceGetAttribute(ctypes.byref(value), number, 0)
    if result:
        raise RuntimeError(f"CUDA attribute query failed: {name}: {result}")
    attributes[name] = value.value
if attributes["pageable_memory_access_uses_host_page_tables"] != 1:
    raise RuntimeError("file-backed PLE hardware precondition is not satisfied")

from sglang.srt.models.qwen4_exp import Qwen4ExpForConditionalGeneration
from sglang.srt.layers.quantization import get_quantization_config

assert get_quantization_config("modelopt_mixed")
target = Path("/models/target")
config = json.loads((target / "config.json").read_text())
index = json.loads((target / "model.safetensors.index.json").read_text())
weight_map = index["weight_map"]
scale_keys = [key for key in weight_map if "weight_scale" in key]
shards = sorted(set(weight_map.values()))
if any(not (target / shard).is_file() for shard in shards):
    raise RuntimeError("checkpoint index contains missing shards")
matrix = torch.arange(64, dtype=torch.bfloat16, device="cuda").reshape(8, 8)
product = matrix @ matrix.T
torch.cuda.synchronize()
if not torch.isfinite(product).all().item():
    raise RuntimeError("BF16 CUDA smoke produced nonfinite values")
torch.manual_seed(42)
q = torch.randn(1, 257, 24, 256, device="cuda", dtype=torch.bfloat16)
k = torch.randn(1, 1025, 2, 256, device="cuda", dtype=torch.bfloat16)
v = torch.randn_like(k)
q_ref = q.float().transpose(1, 2)
k_ref = k.float().transpose(1, 2).repeat_interleave(12, dim=1)
v_ref = v.float().transpose(1, 2).repeat_interleave(12, dim=1)
scores = q_ref @ k_ref.transpose(-1, -2) / 16
mask = torch.arange(1025, device="cuda")[None, :] <= torch.arange(257, device="cuda")[:, None] + 768
scores.masked_fill_(~mask, float("-inf"))
reference = (scores.softmax(-1) @ v_ref).transpose(1, 2)
dense = flash_attn_func(q, k, v, causal=True, num_splits=1)
cu_q = torch.tensor([0, 257], dtype=torch.int32, device="cuda")
cu_k = torch.tensor([0, 1025], dtype=torch.int32, device="cuda")
varlen = flash_attn_varlen_func(q[0], k[0], v[0], cu_seqlens_q=cu_q, cu_seqlens_k=cu_k,
                               max_seqlen_q=257, max_seqlen_k=1025, causal=True, num_splits=1)
errors = {}
for name, result in (("dense", dense), ("varlen", varlen)):
    if isinstance(result, tuple):
        result = result[0]
    result = result.reshape_as(reference).float()
    torch.testing.assert_close(result, reference, atol=0.02, rtol=0.02)
    errors[name] = (result - reference).abs().max().item()
torch.cuda.synchronize()
print(json.dumps({
    "versions": versions,
    "torch_cuda": torch.version.cuda,
    "device": {"name": properties.name, "major": properties.major, "minor": properties.minor},
    "attributes": attributes,
    "architecture": Qwen4ExpForConditionalGeneration.__name__,
    "checkpoint_model_type": config["model_type"],
    "quantization": config["quantization_config"]["quant_method"],
    "checkpoint_scale_key_count": len(scale_keys),
    "checkpoint_shard_count": len(shards),
    "configuration_sha256": hashlib.sha256((target / "config.json").read_bytes()).hexdigest(),
    "bf16_cuda_smoke": "passed",
    "fa4_gpu_max_absolute_error": errors,
}), flush=True)
