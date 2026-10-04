"""Compare the selected Triton block-FP8 kernel with independent FP64 references."""

import json

import torch

from sglang.srt.layers.quantization.fp8_utils import (
    per_token_group_quant_fp8,
    triton_w8a8_block_fp8_linear,
)


torch.manual_seed(42)
results = []
for m, n, k in ((1, 256, 128), (17, 257, 256), (3, 385, 256)):
    x = torch.randn(m, k, device="cuda", dtype=torch.bfloat16)
    blocks = x.view(m, k // 128, 128)
    for block in range(k // 128):
        maximum = 1.75 * (2**block)
        blocks[:, block].clamp_(-maximum, maximum)
        blocks[:, block, 0] = maximum
    if m > 1:
        x[0].zero_()
    weight = torch.randn(n, k, device="cuda").to(torch.float8_e4m3fn)
    scales = (torch.arange(((n + 127) // 128) * (k // 128), device="cuda", dtype=torch.float32)
              .reshape((n + 127) // 128, k // 128) + 1) / 8

    groups = x.float().reshape(m, k // 128, 128)
    input_scales = groups.abs().amax(-1).clamp_min(1e-10) / 448
    quantized = (groups / input_scales[:, :, None]).clamp(-448, 448).to(torch.float8_e4m3fn).reshape(m, k)
    actual_q, actual_scales = per_token_group_quant_fp8(x, 128, column_major_scales=False)
    torch.testing.assert_close(actual_scales, input_scales, rtol=1e-6, atol=0)
    if not torch.equal(actual_q.view(torch.uint8), quantized.view(torch.uint8)):
        raise AssertionError("activation quantizer differs from the independent reference")

    expanded_weight_scales = scales.double().repeat_interleave(128, 0).repeat_interleave(128, 1)[:n, :k]
    reference_weight = weight.double() * expanded_weight_scales
    reference_input = quantized.double() * input_scales.double().repeat_interleave(128, 1)
    reference = reference_input @ reference_weight.T
    weight_only_reference = x.double() @ reference_weight.T
    actual = triton_w8a8_block_fp8_linear(x, weight, [128, 128], scales).double()
    if not torch.isfinite(actual).all().item():
        raise AssertionError("nonfinite block-FP8 output")

    # Bound FP32 accumulation and the final BF16 rounding separately.
    fp32_eps = torch.finfo(torch.float32).eps
    gamma = (k + 4) * fp32_eps / (1 - (k + 4) * fp32_eps)
    absolute_products = reference_input.abs() @ reference_weight.abs().T
    bound = gamma * absolute_products + torch.finfo(torch.bfloat16).eps * reference.abs() + 1e-6
    difference = (actual - reference).abs()
    if not (difference <= bound).all().item():
        raise AssertionError("kernel error exceeds FP32 accumulation plus BF16 rounding bound")
    torch.cuda.synchronize()
    results.append({
        "shape": [m, n, k],
        "activation_quantizer": "bitwise_reference_match",
        "w8a8_fp64_max_absolute_error": difference.max().item(),
        "w8a8_fp64_rmse": ((actual - reference).square().mean().sqrt()).item(),
        "activation_quantization_vs_weight_only_rmse": ((reference - weight_only_reference).square().mean().sqrt()).item(),
        "rounding_and_accumulation_bound": "passed",
    })
print(json.dumps({"status": "passed", "backend": "triton", "block_size": [128, 128],
                  "scope": "small block-FP8 matrices; not full model/head quality", "cases": results}, indent=2), flush=True)
