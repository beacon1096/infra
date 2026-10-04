#!/usr/bin/env python3
"""CPU-only loader checks; optional read-only audit of the existing FP8 head."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
from types import SimpleNamespace


def layer(vocab=248320, hidden=2560, padded=None, **overrides):
    state = SimpleNamespace(
        tp_size=1,
        use_presharded_weights=False,
        num_added_embeddings=0,
        org_vocab_size=vocab,
        embedding_dim=hidden,
        num_embeddings_per_partition=vocab if padded is None else padded,
        quant_method=SimpleNamespace(
            quant_config=SimpleNamespace(weight_block_size=[128, 128])
        ),
        shard_indices=SimpleNamespace(
            org_vocab_start_index=0, org_vocab_end_index=vocab
        ),
    )
    for name, value in overrides.items():
        setattr(state, name, value)
    return state


def tensor_hash(tensor):
    return hashlib.sha256(
        tensor.detach().contiguous().view(torch.uint8).numpy().tobytes()
    ).hexdigest()


def scale_parameter(rows=1940, columns=20):
    return BlockQuantScaleParameter(
        data=torch.full((rows, columns), float("nan"), dtype=torch.float32, device="cpu"),
        input_dim=1,
        output_dim=0,
        weight_loader=load,
    )


def cpu_checks():
    checks = []
    state = layer()
    state.weight = torch.arange(16, dtype=torch.float32, device="cpu").reshape(4, 4).to(
        torch.float8_e4m3fn
    )
    weight_hash = tensor_hash(state.weight)
    markers = torch.arange(1, 1940 * 20 + 1, dtype=torch.float32, device="cpu").reshape(
        1940, 20
    )
    markers_hash = tensor_hash(markers)
    param = scale_parameter()
    load(state, param, markers)
    assert torch.equal(param, markers)
    assert tensor_hash(markers) == markers_hash
    assert tensor_hash(state.weight) == weight_hash
    checks.append("1940x20_all_scalar_markers_loaded_exactly_weight_unchanged")

    param = scale_parameter(2, 2)
    small_scale = torch.tensor([[3.0, 7.0]], dtype=torch.float32, device="cpu")
    load(layer(vocab=128, hidden=256, padded=256), param, small_scale)
    assert torch.equal(param[:1], small_scale)
    assert torch.equal(param[1:], torch.ones((1, 2), dtype=torch.float32, device="cpu"))
    checks.append("pure_padding_scale_blocks_are_ones")

    param = scale_parameter(2, 2)
    partial_scale = torch.tensor(
        [[2.0, 3.0], [5.0, 7.0]], dtype=torch.float32, device="cpu"
    )
    load(layer(vocab=129, hidden=129, padded=192), param, partial_scale)
    assert torch.equal(param, partial_scale)
    checks.append("partial_N_K_blocks_use_ceiling_sizes")

    invalid = [
        ("bad_N", layer(), markers[:-1], AssertionError),
        ("bad_K", layer(), markers[:, :-1], AssertionError),
        ("wrong_scale_dtype", layer(), markers.to(torch.bfloat16), AssertionError),
        ("TP2_rejected", layer(tp_size=2), markers, NotImplementedError),
        ("presharded_rejected", layer(use_presharded_weights=True), markers, NotImplementedError),
        ("added_vocab_rejected", layer(num_added_embeddings=1), markers, NotImplementedError),
    ]
    wrong_block = layer()
    wrong_block.quant_method.quant_config.weight_block_size = [64, 128]
    invalid.append(("non_128_block_rejected", wrong_block, markers, AssertionError))
    for name, state, loaded, error in invalid:
        param = scale_parameter()
        try:
            load(state, param, loaded)
        except error:
            assert torch.isnan(param).all().item(), name
        else:
            raise AssertionError(f"{name} was accepted")
        checks.append(name)

    payload = torch.tensor(
        [[-2.0, -1.0], [0.0, 0.5], [1.0, 2.0], [4.0, 8.0]], device="cpu"
    ).to(torch.float8_e4m3fn)
    before = tensor_hash(payload)
    param = ModelWeightParameter(
        data=torch.empty((6, 2), dtype=torch.float8_e4m3fn, device="cpu"),
        input_dim=1,
        output_dim=0,
        weight_loader=load,
    )
    load(layer(vocab=4, hidden=2, padded=6), param, payload)
    assert torch.equal(param[:4].view(torch.uint8), payload.view(torch.uint8))
    assert torch.equal(param[4:].float(), torch.zeros((2, 2), device="cpu"))
    assert param.dtype == torch.float8_e4m3fn and tensor_hash(payload) == before
    checks.append("ordinary_FP8_loader_payload_bits_and_zero_padding_unchanged")
    try:
        load(layer(vocab=5, hidden=2), param, payload)
    except AssertionError:
        checks.append("ordinary_vocab_assert_retained")
    else:
        raise AssertionError("Ordinary weight loader accepted a bad vocabulary size")
    scalar = torch.nn.Parameter(torch.empty(1, device="cpu"), requires_grad=False)
    load(layer(), scalar, torch.tensor(7.0, device="cpu"))
    assert scalar.item() == 7.0
    checks.append("ordinary_replicated_scalar_loading_retained")
    return checks


def audit_head(path):
    from safetensors import safe_open

    expected = {
        "lm_head.weight": ("F8_E4M3", [248320, 2560], 1),
        "lm_head.weight_scale_inv": ("F32", [1940, 20], 4),
    }
    before_stat = path.stat()
    with path.open("rb") as stream:
        header_length = struct.unpack("<Q", stream.read(8))[0]
        assert 0 < header_length <= 64 * 1024 * 1024
        header = json.loads(stream.read(header_length))
        offsets = {}
        for name, (dtype, shape, element_bytes) in expected.items():
            entry = header[name]
            assert entry["dtype"] == dtype and entry["shape"] == shape
            start, end = entry["data_offsets"]
            assert 0 <= start < end <= before_stat.st_size - 8 - header_length
            assert end - start == shape[0] * shape[1] * element_bytes
            offsets[name] = (8 + header_length + start, end - start)

        def payload_hashes():
            result = {}
            for name, (offset, length) in offsets.items():
                stream.seek(offset)
                digest = hashlib.sha256()
                while length:
                    chunk = stream.read(min(length, 4 * 1024 * 1024))
                    if not chunk:
                        raise EOFError(name)
                    digest.update(chunk)
                    length -= len(chunk)
                result[name] = digest.hexdigest()
            return result

        before = payload_hashes()
        with safe_open(str(path), framework="pt", device="cpu") as checkpoint:
            scales = checkpoint.get_tensor("lm_head.weight_scale_inv")
            assert scales.dtype == torch.float32 and torch.isfinite(scales).all().item()
            param = scale_parameter()
            load(layer(), param, scales)
            assert torch.equal(param, scales)
            weight = checkpoint.get_slice("lm_head.weight")
            sample_starts = [0, 124160, 248192]
            for start in sample_starts:
                sample = weight[start : start + 128]
                assert sample.dtype == torch.float8_e4m3fn and sample.shape == (128, 2560)
                sample_hash = tensor_hash(sample)
                param = ModelWeightParameter(
                    data=torch.empty_like(sample), input_dim=1, output_dim=0, weight_loader=load
                )
                load(layer(vocab=128), param, sample)
                assert torch.equal(param.view(torch.uint8), sample.view(torch.uint8))
                assert tensor_hash(sample) == sample_hash
        assert payload_hashes() == before
    after_stat = path.stat()
    assert (before_stat.st_dev, before_stat.st_ino, before_stat.st_size, before_stat.st_mtime_ns) == (
        after_stat.st_dev, after_stat.st_ino, after_stat.st_size, after_stat.st_mtime_ns
    )
    return {
        "status": "passed",
        "payload_sha256_before_equals_after": before,
        "all_1940x20_scales_loaded_exactly": True,
        "FP8_payload_sample_rows_loaded_bitwise": sample_starts,
        "full_head_GEMM": "not_run",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("manifest.json"))
    parser.add_argument("--head-file", type=Path, help="Existing safetensors shard; opened read-only")
    args = parser.parse_args()
    if sys.flags.optimize:
        parser.error("Do not use Python -O: loader assertion checks must be active")

    global torch, BlockQuantScaleParameter, ModelWeightParameter, load
    import torch
    import sglang.srt.layers.vocab_parallel_embedding as vocab_module
    from sglang.srt.layers.parameter import BlockQuantScaleParameter, ModelWeightParameter

    manifest = json.loads(args.manifest.read_text())
    assert len(manifest) == 1
    source_hash = hashlib.sha256(Path(vocab_module.__file__).read_bytes()).hexdigest()
    assert source_hash == manifest[0]["patched_sha256"], "Patched source must be mounted before import"
    load = vocab_module.VocabParallelEmbedding.weight_loader
    with torch.no_grad():
        checks = cpu_checks()
        audit = audit_head(args.head_file) if args.head_file else {"status": "not_run"}
    print(json.dumps({
        "source_sha256": source_hash,
        "cpu_loader": {"status": "passed", "checks": checks},
        "real_head_read_only_audit": audit,
        "GPU_numerical_parity": "not_implemented_not_run",
        "scope": "TP1, non-presharded, no added vocabulary; no GPU or model forward",
    }, indent=2), flush=True)


if __name__ == "__main__":
    main()
