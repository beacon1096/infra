# Qwen3.8-27B: original NVFP4 and speculation

[Thor overview](../../thor.md)

Retest: 2026-09-12. The [Huihui trial](huihui-qwen3.8-27b.md) compares a
modified target and includes the subsequent DFlash2 profiling.

Measured on the Jetson AGX Thor T5000 (SM110), Linux 6.8.12, in the
`nvpmodel` 120W mode. Earlier exploratory runs overlapped with kernel compilation;
the results below replace those performance comparisons. No background build was
running during this retest. Per-second `vmstat` samples showed approximately
92.5% average CPU idle, at least 90% idle, and zero I/O wait across all four groups.

All groups used the same ARM64 SGLang DFlash2 image and target checkpoint:

| Component | Pinned version |
| --- | --- |
| Image | `lmsysorg/sglang@sha256:088ce12e606cb39b4fc2a20f0bd7c44c512126a29ebbb5c717a1ca0889f093c9` |
| Image build | `5f55db35e926d50676f75b812640ea2410b0fe0e`, CUDA 13.0.3 |
| Target | `RadixArk/Qwen3.8-27B-NVFP4-BF16-LMHead` at `009632fef96dd349150baa780c984e62e70e91fe` |
| DFlash2 draft | `z-lab/Qwen3.8-27B-DFlash2` at `50307d4c4cde6860d4eee73e2547cd786fe8e8a4` |

## Method and results

Single request at a time, 4096-token context, `temperature=0`, and
`chat_template_kwargs={"enable_thinking":false}`. Each workload first received
a 32-output-token warmup, followed by three measured runs. The prefix cache was
flushed before every request. Generation caps can truncate responses; this is a
throughput test, not a complete code-correctness evaluation.

| Workload | Output-token cap | Exact prompt |
| --- | ---: | --- |
| Chinese | 256 | 用中文详细解释设备树如何帮助Linux启动，分五点说明，约400字。 |
| Short code | 256 | 请写一个Python函数判断整数是否是质数，并给出五个测试用例，然后解释时间复杂度。 |
| Long code | 1024 | 请实现一个完整的Python LRU缓存类，使用双向链表和字典，支持get和put，提供详尽的单元测试。直接输出代码，尽可能完整。 |

Values are median output tokens/s over three runs, calculated as
`(completion_tokens - 1) / (stream_end - first_nonempty_content_chunk)`.
This is a streaming decode estimate excluding time to first content, not
end-to-end throughput; a speculative stream chunk can contain multiple tokens.

| Configuration | Chinese | Short code | Long code |
| --- | ---: | ---: | ---: |
| No speculation | 13.04 | 13.04 | 13.01 |
| EAGLE/MTP, steps/top-k/draft tokens = 3/1/4 | 19.61 | 31.14 | 29.56 |
| DFlash2, 8 draft tokens, Triton draft attention | **20.50** | 44.95 | **55.92** |
| DFlash2, 8 draft tokens, FA4 draft attention | 18.39 | **45.29** | 54.58 |

DFlash2 with Triton was retained: long-code throughput was about 4.3 times the
no-speculation baseline. The roughly 56 tokens/s result was reproduced without
background compilation. The reported 125–133 tokens/s in the external article
has **not** been reproduced with these workloads and settings.

## Retained experimental configuration

The container uses NVIDIA CDI (`--device=nvidia.com/gpu=all`), 8 GiB shared
memory, and a loopback-only API port. Target and draft were loaded from local
snapshots at the revisions above. The NixOS host enables Docker and the NVIDIA
container toolkit; model serving remains an experiment, without a declarative
service or automatic startup.

Common server settings:

```text
--context-length 4096 --max-running-requests 1 --max-total-tokens 8192
--mem-fraction-static 0.65 --chunked-prefill-size 1024
--attention-backend triton --linear-attn-backend triton
--kv-cache-dtype bfloat16 --fp4-gemm-backend flashinfer_cutlass
--mamba-ssm-dtype bfloat16 --max-mamba-cache-size 8
--cuda-graph-backend-decode full --cuda-graph-max-bs-decode 1
--cuda-graph-backend-prefill disabled
--reasoning-parser qwen3
```

DFlash2 adds the pinned draft snapshot as `--speculative-draft-model-path` and:

```text
--speculative-algorithm DFLASH --speculative-num-draft-tokens 8
--speculative-draft-model-quantization unquant
--mamba-radix-cache-strategy extra_buffer
```

The FA4 comparison adds `--speculative-draft-attention-backend fa4`. The
no-speculation baseline omits speculative arguments; MTP instead uses
`--speculative-algorithm EAGLE --speculative-num-steps 3
--speculative-eagle-topk 1 --speculative-num-draft-tokens 4` with the target's
MTP weights. Those two groups retain the default Mamba radix-cache strategy.

Compatibility findings from exploratory runs, not additional retest rankings:

- Full-model FA4 failed on the `head_dim=256` variable-sequence interface.
  FA4 for the DFlash2 draft alone started successfully and was retested above.
- DFlash2 with `torch.compile` failed during startup/graph capture and is not
  included in the results. Decode CUDA Graph remains enabled without that flag.
- The older pinned CUDA 13.0.3 image was selected for the installed driver;
  the newer CUDA 13.4 image was not validated.

## Original-model draft-head INT8 follow-up

On 2026-09-13, the same original checkpoint, DFlash2 draft, pinned SGLang
runtime and three-workload protocol reproduced 20.510 / 44.993 / 55.966
tokens/s. All nine measured response texts matched the previous original-model
baseline. This follow-up does not reuse Huihui measurements as original-model
results.

Original-model traces each contained eleven draft and eleven target Graph
replays. Both graphs included one complete BF16 vocabulary projection of shape
`[248320,5120]`, about 9.78 ms in the draft and 9.73 ms in the target. The
original target Graph took about 81–83 ms, versus about 70–71 ms in the older
Huihui traces. Those targets have different precision mixes: the original
trace contains 128 FP8 GEMMs and corresponding FP8 activation quantizations
where the Huihui trace has 128 additional NVFP4 GEMMs. Do not treat the two
checkpoints as an identical-kernel runtime comparison just because both
carry an NVFP4 label; exact module mapping still needs direct shape evidence.

### Preserve the DFlash2 selector

The actual captured path is `_SelectorDraftSampler` → `_selector_lattice` →
`DFlash2DraftModel.compute_candidates` in `sglang/srt/models/dflash.py`.
It projects the complete vocabulary, then applies radix top-k, unary-logit
transformation and the learned selector. The ordinary `_DflashDraftSampler`
matmul is a different path. An initial integration guard rejected this
selector configuration before serving, and the BF16 service was restored;
this was an integration error, not a failed INT8 numerical probe.

The corrected experiment replaces only the TP1 full-vocabulary projection
inside `compute_candidates`, before the existing top-k. Graph and eager
execution retain the selector and target verification. A separate per-row
INT8 weight copy is built before draft Graph capture; activations use dynamic
per-row INT8 scaling, INT32 accumulation and BF16 output. Small row counts
are padded to 32 for the integer GEMM. All 248320 vocabulary entries remain
available. The shared target head stays BF16; the draft copy adds about
1.184 GiB rather than shrinking target memory.

The real checkpoint head passed M7/M8 checks against an independent FP64
integer-dot implementation of the same quantization, plus empty/zero-input
and changing-buffer CUDA Graph checks. Including activation quantization and
rescaling, standalone Graph medians were 9.787 → 5.043 ms at M7 and
9.790 → 5.104 ms at M8. These initial inputs were synthetic.

### Serving results and real hidden states

Sampling was disabled during the three-run streaming benchmark:

| Workload | BF16 draft head | INT8 draft head | Change | Response text |
| --- | ---: | ---: | ---: | --- |
| Chinese | 20.510 TPS | 20.670 TPS | +0.8% | Changed |
| Short code | 44.993 TPS | 46.934 TPS | +4.3% | Identical |
| Long code | 55.966 TPS | 57.682 TPS | +3.1% | Changed |

Each INT8 workload was stable across its three measured repetitions. Separate
native `/generate` requests used the same chat-template token IDs and matched
the corresponding streaming outputs. Their per-request speculative counters
reported acceptance rates of 17.67% → 16.71% for Chinese, 57.69% → 57.69% for
short code and 74.81% → 73.31% for long code. These are single-request counter
comparisons, not the server's log-window or cumulative averages. Accepted-length figures
were 2.246 → 2.169, 4.923 → 4.923 and 6.206 → 6.132 respectively. Proposal
accounting can extend beyond a requested output cap. Changed Chinese/long-code
trajectories prevent attributing their entire throughput difference to the
faster projection.

| Median Graph GPU span | Chinese BF16 → INT8 | Long code BF16 → INT8 |
| --- | ---: | ---: |
| Draft | 23.366 → 18.825 ms | 23.622 → 19.145 ms |
| Target verification | 80.885 → 80.842 ms | 82.705 → 82.796 ms |

All 1066 target kernels per replay retained identical names, grids and counts.
In the draft, the other 131 kernels were unchanged: one BF16 head was replaced
by the integer GEMM and quantization/rescaling, 16 kernels in total. Thus the
roughly 4.5 ms draft reduction is directly visible, while target time remains
similar. Kernel sums are not exclusive wall time or service throughput.

Default-off sampling then collected 16 Chinese and 16 short-code steps from
the INT8 service, seven real hidden rows per step. All 32 saved samples exactly
reproduced their pre-selector candidate IDs and logits when recomputed with
the same deterministic radix top-k. BF16 versus INT8 head argmax differed on
3/112 Chinese rows and 1/112 code rows. Final selector tokens are not generally
head argmax and were not used as that reference. These are INT8-trajectory
samples, not paired BF16/INT8 generation trajectories or broad quality proof.

A 2823-token retrieval prompt passed three times, including prefix reuse.
JSON was correct; a complete generated primality function exactly matched the
BF16 response already validated by its five assertions and 10033 independent
sieve checks over integers -32 through 10000. The throughput code responses
remain capped and are not complete-program quality tests.

The INT8 experimental service was retained with profiling and hidden sampling
off, health 200 and approximately 83 GiB host memory available. The original
BF16 container and Flash Next launch configuration remain available for
rollback. The clearest measured gain is short-code throughput at identical
text and acceptance. Next inspect the original target's FP8 projection
shapes and kernel choices while retaining its current weights and precision.
Raw scripts, traces and hidden-state samples remain outside Git.

## Original target FP8 backend probe (2026-09-13)

The retained INT8-draft service spends 27.985 ms (Chinese) / 30.107 ms
(long code) per target replay in 128 FP8 attention projections. Checkpoint
and runtime inspection mapped them to these merged weight shapes:

| Projection | Calls per replay | Weight shape `[N, K]` | Chinese / long-code kernel sum |
| --- | ---: | --- | ---: |
| GDN QKV/Z input | 48 | `[16384, 5120]` | 15.204 / 15.347 ms |
| Attention output | 64 | `[5120, 6144]` | 8.353 / 10.310 ms |
| Full-attention QKV | 16 | `[14336, 5120]` | 4.428 / 4.450 ms |

The 128 static FP8 activation quantizations add about 0.277 ms. The current
GEMMs use CUTLASS SM100-family kernels on SM110, with FP8 E4M3 operands.
The probe loaded representative real layer 0/3 weights, reproduced SGLang's
maximum-scale requantization when merging shards, and kept the same static
activation quantization. Inputs were synthetic BF16 hidden states.

CUDA Graph GEMM medians at M8, in milliseconds (five batches of 50 replays):

| Backend | QKV/Z | Output | QKV |
| --- | ---: | ---: | ---: |
| Current SGLang CUTLASS | 0.316970 | 0.117955 | 0.277806 |
| Torch scaled MM | 0.316388 | 0.120396 | 0.280870 |
| Torch scaled MM, fast accumulation | 0.317197 | 0.119820 | 0.280940 |
| FlashInfer cuBLAS | 0.342858 | 0.119924 | 0.280975 |
| FlashInfer CUTLASS | 0.318436 | 0.117555 | 0.277946 |

M1 was also measured; no alternative improved the current baseline there.
The best alternative pure-GEMM differences at M8 are below 0.4%.
With activation quantization and an identical FP8 copy included, one output
projection batch measured 0.121337 ms for the baseline versus 0.115972 ms for
FlashInfer CUTLASS (4.4%). The latter is even below its separately measured
pure-GEMM time, showing that these sequential batches are sensitive to cache
state and timing variation. Repeated single-layer replays also differ from
a full model. This isolated result does not establish an end-to-end gain or
justify a service change.

Across three shapes, M1/M8 and random/changed/zero inputs, FlashInfer CUTLASS
matched the current output bitwise in all 18 cases. Torch and cuBLAS each
matched 11/18; all outputs were finite, with maximum absolute differences
of 0.0078125 and 0.015625 respectively. This is a limited numerical check,
not a model-quality evaluation. All 120 changing-input CUDA Graph checks
matched their own backend's eager output bitwise, including zero and recovery
after zero. The three baseline probe kernel names and grids matched the
serving trace exactly. Probe peak PyTorch allocation was below
351 MiB, with peak reserved memory below 395 MiB; these exclude the running
server and non-PyTorch allocations.

No backend was promoted and no serving throughput gain is claimed. The
original target weights and INT8 draft service remain unchanged. Raw scripts,
results and traces are retained outside Git. The next useful experiment is
GDN attention-state/kernel overhead on this original checkpoint; another
wrapper around these FP8 GEMMs is not supported by the measured results.

## References

- [Original SGLang deployment reference for DGX Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — adapted and measured on Thor; its Spark CPU affinity and attention settings are not directly transferable.
- [Lazycat technical lead's model adaptation report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
