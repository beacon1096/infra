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

## Original target GDN tiling experiment (2026-09-13)

The preceding INT8-draft traces attribute 4.234 ms (Chinese) / 3.691 ms
(long code) of each target replay to GDN recurrent update, convolution,
QKV/Z splitting and gated normalization. Recurrent update alone accounts
for 3.238 / 2.667 ms across 48 calls, with grid `[1, 4, 48]`. Outside the
graph, SSM state and convolution-window scatter add approximately 0.738 ms
per verification round. These kernel sums are not exclusive wall time.

DFlash verifies eight valid tokens per round in this configuration. The
acceptance count selects a saved state after verification; it does not shorten
the recurrent loop. SSM verification keeps its source state intact and saves
BF16 state snapshots at every step. Convolution verification has different
write-back behavior and its accepted window is restored during commit.

The installed FlashInfer backend's verification guard excludes SM110, and
the CuteDSL backend has no target-verification implementation. Instead of
switching backend, this experiment swept the existing Triton kernel's value
block size (16/32/64) and warp count (1/2/4), keeping three stages.
Only the one-warp configurations passed all bitwise checks; the larger warp
counts changed numerical results and were rejected.

The probe used synthetic packed Q/K/V with the model's 16 key heads, 48 value
heads and 128-dimensional key/value heads, plus nonzero BF16 initial state.
It checked all per-token snapshots, unchanged source state, nonzero pool
indices, untouched padding and an allocated snapshot stride larger than the
runtime token count. Changing-input CUDA Graph checks also compared output
and snapshots with the original kernel.

A second probe held inputs fixed and alternated baseline/candidate order
across ten batches of 100 Graph replays:

| Valid tokens | Original BV32, one warp | BV16, one warp | Kernel reduction |
| --- | ---: | ---: | ---: |
| 1 | 0.012309 ms | 0.010264 ms | 16.6% |
| 3 | 0.023340 ms | 0.018680 ms | 20.0% |
| 8 | 0.056102 ms | 0.041098 ms | 26.7% |

All three fixed-input comparisons were bitwise equal. The candidate patch
is opt-in and limited to SM110, batch one, the original eight-token verify
shape, BF16 state and inputs, and the existing non-tree/non-KDA/non-ring
path. It changes BV alone; arithmetic, warp count and state commit remain
unchanged. These standalone checks do not replace service-level validation.

### Service A/B

A fresh baseline reproduced the previous INT8 service's texts and throughput.
The same three workloads, with one short warmup and three measured repetitions
each, then produced:

| Workload | Original BV32 | Candidate BV16 | Change |
| --- | ---: | ---: | ---: |
| Chinese | 20.671 TPS | 20.792 TPS | +0.59% |
| Short code | 46.930 TPS | 47.206 TPS | +0.59% |
| Long code | 57.681 TPS | 58.023 TPS | +0.59% |

All nine measured response texts and token usages were identical. Candidate
and baseline throughput ranges did not overlap in these three repetitions;
this remains a small fixed-workload experiment, not a broad performance claim.

| Profile metric | Chinese BV32 → BV16 | Long code BV32 → BV16 |
| --- | ---: | ---: |
| Recurrent kernel sum per target replay | 3.238 → 2.652 ms | 2.667 → 2.073 ms |
| Target Graph median span | 80.842 → 80.253 ms | 82.796 → 82.107 ms |
| Draft Graph median span | 18.825 → 18.813 ms | 19.145 → 19.115 ms |

Each trace contained 11 draft/target replays. The only target kernel-grid
change was the 48 recurrent calls, from `[1, 4, 48]` to `[1, 8, 48]`.
All other target kernel names, grids and counts were unchanged, as were all
draft kernels. The approximately 0.59 ms recurrent reduction is visible in
both workloads; whole-model savings are smaller than the standalone 27%.

Five native requests (the three workloads, JSON and a complete primality
function) retained identical texts and all per-request speculative counters.
Chinese/short-code/long-code acceptance remained 16.71% / 57.69% / 73.31%.
The functional response was identical to the previously validated program;
the capped throughput responses are still not complete-program quality tests.
A 2823-token retrieval prompt passed three times, including prefix reuse.

The BV16 configuration was selected for the experimental service after these
checks. After restart, retrieval passed three more times, health was 200,
hidden sampling remained off and the memory watchdog was active. The original
INT8-draft/BV32 container remains available for rollback.
This is a roughly 0.6% service improvement, not the standalone kernel's 27%.
Raw probes, patch generator, launch/rollback scripts and traces remain outside
Git. Further work should prioritize larger measured costs, such as the target
LM head, while preserving target precision and validating generated output.

## Original target BF16 head backend probe (2026-09-13)

The retained GDN-BV16 service spends 9.812 ms per verification replay in the
full-vocabulary target head. Its actual entrypoint is `torch.matmul` with
BF16 hidden states and transposed BF16 weights, producing BF16 logits before
copying them into the FP32 sampling buffer. Verification projects all eight
rows. Direct FP32 GEMM output would bypass this BF16 rounding step and was
not treated as an equivalent replacement.

The real `[248320, 5120]` head contains 2542796800 bytes (2.368 GiB).
Dividing that size by the serving time gives approximately 259 GB/s; this
is a weight-bytes/time ratio, not a measured memory-bandwidth ceiling.
The standalone probe checked the complete vocabulary and recorded the raw
weight SHA256, while using synthetic BF16 hidden states. It retained the
existing reduced-precision-reduction setting and did not quantize the head.

All backends shared fixed inputs during timing. Five batches of 20 CUDA Graph
replays alternated forward/reverse backend order. GEMM medians, excluding the
subsequent FP32 copy:

| Backend | M8 | M1 |
| --- | ---: | ---: |
| Current Torch matmul | 9.7837 ms | 9.8691 ms |
| Torch F.linear | 9.7457 ms | 9.8404 ms |
| Torch addmm, beta=0 | 9.7515 ms | 9.8251 ms |
| Vocabulary chunks of 65536 plus concatenation | 9.8734 ms | 9.9349 ms |
| FlashInfer cuBLASLt | 9.7672 ms | 9.8292 ms |
| FlashInfer cuDNN | 9.7769 ms | 9.8669 ms |
| FlashInfer TinyGEMM | 9.4113 ms | 9.4230 ms |

The baseline, F.linear, addmm, cuBLASLt and cuDNN dispatched identical kernel
names and grids at each M. At M8 they exactly matched the serving trace's
`nvjet_sm110_tst_128x8_64x12_2x1_v_bz_TNT`, grid `[1940, 1, 1]`.
Their outputs were bitwise identical in all eight random/changed/zero/recovery
cases per backend. Their sub-0.5% timing differences do not establish a useful
backend change when the captured GPU work is the same.

All 56 changing-input Graph checks matched their own backend's eager output,
were finite and retained the baseline argmax on these synthetic inputs.
TinyGEMM and vocabulary chunking nevertheless differed from baseline logits
in all six nonzero cases each, with maximum absolute difference 0.03125.
Their worst differing-element fractions were 0.234% and 0.122% respectively.
TinyGEMM's M8 improvement is approximately 3.8% (0.372 ms), but unchanged
synthetic argmax is not evidence of equivalent target acceptance or sampling
on real hidden states. No service A/B or model-quality claim was made for it.

No head backend was promoted. The existing INT8-draft/GDN-BV16 service remained
healthy with its memory watchdog active and hidden sampling off. Probe peak
PyTorch allocation/reservation was 2.506/2.627 GiB, excluding the server and
non-PyTorch allocations. Raw scripts, checksums, numerical results and kernel
traces remain outside Git. The next larger measured target cost is the pair
of NVFP4 projection groups, about 37 ms per replay; inspect their actual shapes
and tactics before proposing another service change.

## Original target NVFP4 tactic probe (2026-09-13)

The retained service's 128 NVFP4 GEMMs are the 64 merged gate/up projections
and 64 down projections. They account for 36.973 ms (Chinese) / 37.074 ms
(long code) per target replay:

| Projection | Logical weight `[N, K]` | Packed U8 weight | Serving grid | Mean time per call, Chinese |
| --- | --- | --- | --- | ---: |
| Gate/up | `[34816, 5120]` | `[34816, 2560]` | `[2, 272, 1]` | 0.3812 ms |
| Down | `[5120, 17408]` | `[5120, 8704]` | `[1, 40, 1]` | 0.1965 ms |

The probe loaded real layer 0 weights and reproduced the original runtime
scale processing: block-16 E4M3 scales in the 128-by-4 swizzled layout,
maximum shard input/global weight scales, and their product as GEMM alpha.
These shapes need no padding. Packed weights were not requantized, and
activations used the installed SGLang `fp4_quantize` on synthetic BF16 inputs.

An initial signature guard correctly stopped the probe: the independent
FlashInfer wrapper's default kernel differed from the serving kernel despite
an identical grid. SGLang loads a persistent FlashInfer autotune cache during
startup; the standalone wrapper had not loaded it. Thus neither uncached
wrapper timing nor raw tactic `-1` is the service baseline.

The complete M8 sweep covered 32 explicit CUTLASS tactics plus the uncached
wrapper and raw default for each shape. All 68 combinations ran, and all
272 changing-input Graph checks matched both their own eager output and the
wrapper output bitwise, including zero and recovery. The full kernel name
and grid uniquely identified serving tactic 4 for gate/up and 21 for down;
the saved service autotune cache independently confirmed both IDs. These
IDs are specific to the installed FlashInfer build and these shapes.

The first sequential scan suggested only small improvements among explicit
tactics. It also produced an unusually fast down-wrapper sample (0.1762 ms)
that its identical raw kernel did not reproduce (approximately 0.1953 ms).
This discrepancy required fixed-input interleaved confirmation before any
service conclusion. The raw first attempt and complete scan are retained.

The confirmation held inputs fixed and rotated/reversed candidate order
across ten batches of 50 Graph replays. It measured both GEMM alone and the
original activation-quantization-to-GEMM path, without an artificial FP4 copy
inside the timed graph:

| Projection / tactic | GEMM | Quantization + GEMM |
| --- | ---: | ---: |
| Gate/up: serving 4 | 0.383210 ms | 0.387218 ms |
| Gate/up: 6 | 0.382875 ms | 0.386581 ms |
| Gate/up: uncached wrapper | 0.382726 ms | 0.386377 ms |
| Down: serving 21 | 0.198322 ms | 0.203461 ms |
| Down: 29 | 0.198083 ms | 0.202881 ms |
| Down: 0 | 0.197301 ms | 0.202329 ms |
| Down: uncached wrapper | 0.197597 ms | 0.202400 ms |

All 56 additional changing-input checks matched the serving tactic and their
own eager output bitwise. Both serving tactics again matched the full serving
kernel signature. The unusually fast down-wrapper result did not reproduce.
The best nominal complete-path differences were 0.22% for gate/up and 0.56%
for down. Summing the per-call time differences over 64 calls of each
projection gives only about 0.126 ms per verification round, before accounting
for full-model cache behavior or
integration overhead; this is not a measured service gain.

No tactic override was deployed. The original INT8-draft/GDN-BV16 service
remained healthy, with its watchdog active and hidden sampling off. All
probes used synthetic activations and representative real layer 0 weights;
there was no new service throughput or model-quality experiment. Raw scripts,
autotune evidence, first-attempt failure and traces remain outside Git.
With the tested exact-output kernel alternatives largely exhausted, the next
experiment should compare DFlash draft block sizes on the existing workloads,
especially the Chinese case with low draft acceptance.

## DFlash block-size comparison (2026-09-13)

This experiment compares block sizes 4 and 16 with the retained block-8
service. A block includes one anchor token, so sizes 4/8/16 propose at most
3/7/15 draft tokens respectively. The draft checkpoint declares block size 8;
the installed runtime permits an override and synchronizes draft convolution
boundaries, mask/position buffers and selector lengths. Runtime support does
not establish training or quality coverage for the overridden size.

Draft attention is non-causal, so block 4 is not simply a truncation of the
first three block-8 proposals. Changed verification/commit boundaries can
also affect BF16 computation. Cross-size response equality was measured,
not assumed. The comparison retains the existing GDN guard: block 8 uses the
validated BV16 optimization, while blocks 4 and 16 use original BV32. It compares
actual deployment configurations rather than isolating block size alone.

The first block-4 launch was rejected by the experimental hidden-capture
startup guard. Merely removing the sampling trigger file was insufficient:
setting its capture-directory environment variable still constructs a
block-8-only diagnostic object. The retry omitted the capture-directory and
limit variables entirely, leaving the independent INT8-head switch enabled.
No guard was weakened. The failed launch log and rollback were preserved.

A fresh block-8 baseline reproduced the retained service's response texts.
Each configuration used one short warmup and three measured repetitions per
workload, with the same sampling settings, prompts and output caps:

| Workload | Block 4 | Block 8 | Block 16 | Block 4 / 16 change versus 8 |
| --- | ---: | ---: | ---: | ---: |
| Chinese | 19.272 TPS | 20.742 TPS | 19.474 TPS | -7.1% / -6.1% |
| Short code | 35.289 TPS | 47.094 TPS | 72.454 TPS | -25.1% / +53.9% |
| Long code | 35.145 TPS | 57.883 TPS | 74.560 TPS | -39.3% / +28.8% |

Each configuration was text-stable across its three repetitions, but all
nine measured responses changed between block 8 and each alternative.
Token usages remained identical. These are observed workload differences,
not equal-text speedups or isolated arithmetic savings.

Native requests using the same tokenized prompts reported these per-request
counters (block 8 / block 4 / block 16):

| Workload | Draft acceptance rate | Accepted length per round | Verification rounds |
| --- | --- | --- | --- |
| Chinese | 16.71% / 32.31% / 7.62% | 2.169 / 1.969 / 2.151 | 118 / 130 / 119 |
| Short code | 57.69% / 87.32% / 47.50% | 4.923 / 3.606 / 8.000 | 52 / 71 / 32 |
| Long code | 73.31% / 88.02% / 48.78% | 6.132 / 3.644 / 8.325 | 167 / 281 / 123 |

A higher acceptance percentage alone was misleading: block 4 accepted fewer
tokens per round and required more verification rounds. Block 16 reduced
code verification rounds substantially despite its lower acceptance rate.
These counters belong to the observed, different output trajectories; proposal
accounting may extend beyond the requested output cap.

The traces contained 11 draft/target replays per workload. Target/draft Graph
medians in milliseconds, using the retained block-8 reference traces:

| Workload | Block 8 target / draft | Block 4 target / draft | Block 16 target / draft |
| --- | --- | --- | --- |
| Chinese | 80.253 / 18.813 | 79.023 / 18.809 | 85.939 / 19.027 |
| Long code | 82.107 / 19.115 | 80.150 / 19.003 | 87.922 / 19.260 |

Block 4 did not halve per-round cost. It still ran all model projections,
and the INT8 draft head padded both three and seven input rows to M32.
Block 16 paid more per verification round, but its code workloads accepted
enough additional tokens to improve throughput. This explains the direction
of the measurements without attributing all differences to one kernel.

Both alternatives passed the 2823-token retrieval test three times, including
prefix reuse. JSON remained correct. Block 4's complete primality response
matched the previously validated program. Block 16 produced a different
complete program that passed its five generated assertions and an independent
sieve comparison over -32 through 10000 (10033 checks). Capped throughput
responses were not treated as complete-program quality tests.

Block 16 was selected for the experimental service, prioritizing measured
code throughput while accepting the roughly 6% Chinese slowdown. INT8 draft
projection remains enabled; the narrow GDN-BV16 optimization is inactive at
block 16, which uses original BV32. The validated block-8 container remains
available for rollback. Raw launchers, failure logs, benchmark responses,
profiles and checks stay outside Git. Performance tuning is paused; the
next priority is a persistent OpenAI-compatible service through the shared
LiteLLM entrypoint. Further tuning waits for infrastructure stabilization
and operational handover.

## Context capacity assessment and deferred YaRN tests — 2026-09-14

This was a read-only assessment; the service was not enlarged or restarted.
Both pinned target and DFlash2 draft configurations declare
`max_position_embeddings=262144` with default RoPE, so native 256K does not
require YaRN. The deployed 4096-token context and 8192-token KV pool were
explicit experiment limits, not measured hardware capacity limits.

With the model running, the host reported approximately 122 GiB total,
40 GiB used and 82 GiB available memory. Target attention has 16 full-attention
layers (4 KV heads, head dimension 256) and 48 linear-attention layers;
the draft has 5 layers (8 KV heads, head dimension 128). Current KV dtype is
BF16. The target and draft KV allocations therefore cost 64 and 20 KiB/token,
respectively, matching startup logs at 8192 tokens.

| Context/pool tokens | Target KV | Draft KV | Combined KV |
| --- | --- | --- | --- |
| 32768 | 2 GiB | 0.625 GiB | 2.625 GiB |
| 65536 | 4 GiB | 1.25 GiB | 5.25 GiB |
| 131072 | 8 GiB | 2.5 GiB | 10.5 GiB |
| 262144 | 16 GiB | 5 GiB | 21 GiB |

These are calculated cache sizes, not measured long-context memory peaks.
Existing Mamba/state buffers consume about 2.93 GiB at 8 cache slots and
block16. The inspected DFlash prefill path immediately writes each chunk's
auxiliary hidden states into draft KV rather than retaining a second full
history of those states. Temporary attention/workspace allocations and
long-input behavior still need measurement.

A candidate native-context test is `--context-length 262144
--max-total-tokens 270336`, retaining chunked prefill 1024, memory fraction
0.65, one active request, BF16 KV and block16. The larger pool includes 8192
extra slots and calculates to 21.65625 GiB of combined KV. Increasing only
context length would leave the old token-pool bottleneck. SGLang may also
clamp the requested pool to its memory-profiled capacity; verify actual
startup allocation. Input and output share the context, with additional
scheduler boundary reservations.

### Manufacturer technical lead's reports (not local measurements)

The references below were published by ManateeLazyCat, the Lazycat
manufacturer's technical lead. The two YaRN reports are dated 2026-08-28.

- [YaRN 768K context test](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-yarn-768k/): reports 1M startup failure (83.68 GiB KV required versus 80.32 GiB available); 768K startup success with `max_model_len=786432` and approximately 882K token cache capacity; and a successful 100K-token request under a 512K configuration. The 760K/500K requests did not produce a first token within the test window. Reported unified-memory use was 107.5/125.8 GB with about 17 GB available. Its then-current 768K conclusion is a configuration-specific result, not a universal maximum.
- [900K code context report](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-900k-context/): subsequently reports extending the 786K configuration to 900K using YaRN, with about 120 GB memory use. It also quotes 133 tokens/s single-stream performance, but does not establish that speed at a 900K prompt. The article does not provide the exact token count behind “900K”, complete runtime/YaRN/KV/draft settings, timed long-request results or retrieval/quality measurements. Treat 900K as a reported achieved configuration to investigate, not a proven maximum or a reproduced stable-service result.

The [2026-08-27 throughput report](https://manateelazycat.github.io/2026/08/27/qwen-3-8-27b-125-tokens/) additionally reports prefill 3754 TPS, long-code decode 125 TPS, eight-session code decode 231 TPS and memory use 70 GB on one Lazycat unit. It does not provide per-session rates, prompt/output lengths, exact context occupancy, quantization or runtime settings. Do not interpret 231 TPS as the rate of each session, or combine these figures with the later 900K report to claim eight simultaneous 900K requests. This is a separate future concurrency comparison; first qualify native 256K with one active request.

### Deferred validation checklist

- Validate native 256K first, with progressively larger real inputs, retrieval at several positions, prefix reuse and generation near the shared context boundary.
- Then investigate YaRN 512K → 768K (`786432`) → the reported 900K setting. Obtain exact target/draft RoPE settings, runtime revision, KV dtype, cache capacity, concurrency and hardware configuration before comparing results; do not invent missing parameters from the article titles.
- Record exact input/output tokens, startup and peak memory, first-token latency, decode throughput, finish reason and correctness. Distinguish startup, first-token response and full-request completion.
- Check long-prefill progress against the generation-health monitor and API timeouts. Streaming alone does not guarantee an early model token. Keep existing memory protection; do not copy a reported 120 GB occupancy by lowering safety margins.

Performance tuning remains deferred. These references preserve future capacity-test targets; no YaRN setting or larger advertised context was deployed by this documentation update.

## References

- [Original SGLang deployment reference for DGX Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — adapted and measured on Thor; its Spark CPU affinity and attention settings are not directly transferable.
- [Lazycat technical lead's model adaptation report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
