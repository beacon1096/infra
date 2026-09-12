# Qwen3.8 Flash Next: NVFP4, CUDA Graph and MTP

[Thor overview](../../thor.md)

Source review: deployment revision `d03809008834124e80223c3482f2ddb59577a48f`.
Local startup and performance experiments: 2026-09-13.

## Checkpoint and memory layout

Qwen3.8 Flash Next is the more practical next candidate while retaining a
desktop. Its approximately 99 GiB checkpoint includes a 26.82 GiB PLE table,
leaving approximately 72 GiB of GPU-resident weights. The additional packed PLE
file is a disk copy mapped by a CPU worker, not an additional 27 GiB that must
always be resident. The deployment reserves 26 GiB of host memory by default;
PLE page cache, desktop processes and driver allocations share that reserve.
Full advertised context and concurrency have not been validated on Thor.

## Runtime and operator compatibility

The pinned ARM64 image is
`vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e`.
A local container probe reported Torch 2.13.0+cu130, vLLM
`0.1.dev20073+g8e685d198`, FlashInfer 0.6.17, Triton 3.7.1 and CUTLASS DSL 4.6.2.
Torch includes SM110 and passed a small BF16 CUDA matrix multiplication on Thor.
Additional small-tensor probes ran with networking disabled:

| Path | Observed result |
| --- | --- |
| GDN packed decode, BF16 state/output | Single-token zero-state reference passed; maximum absolute error 0.0000529 |
| MXFP8 FlashInfer CUTLASS GEMM | Random-matrix comparison to BF16 reference: cosine 0.999285 |
| NVFP4 FlashInfer CUTLASS MoE | Two small experts with nonzero constant weights: maximum absolute error 2.5 against an output near 93.6 |
| QSA BF16 scoring and sparse attention | Reference errors approximately 0.00000191 and 0.000551 |
| QSA default cooperative top-k | Failed with CUDA cluster misconfiguration on SM110 |

The QSA dispatcher selects cooperative top-k for capability >=90 outside the
SM120 family, which also selects it on Thor. The image's existing persistent
top-k implementation executes successfully. A temporary bind-mounted patch
excluding the SM110 family from the cooperative branch also passed the complete
selector call. A follow-up selecting 512 of 1024 visible candidates matched
`torch.topk` as an index set, with no tie at the cutoff; subsequent attention
had maximum absolute error 0.000515. This is a compatibility workaround, not a model
throughput result; the unmodified image still has the failing default path.

A follow-up combined the repository's FP8 KV patch with the SM110 selector
fix. Native FP8 and uint8-backed caches passed against explicitly dequantized
references with non-unit K/V scales. Selecting 512 of 1024 candidates also
passed. Separate selector and attention CUDA graphs remained correct across
three replays with in-place query, KV and scale changes; attention maximum
absolute error was below 0.000648. This checks implementation against the same
quantized inputs, not model quality relative to BF16 weights or caches.

The fixed checkpoint at `925d7be6c14c6c9442ef83e8f05b5a3c39304f69` uses NVFP4
W4A4 for its 48 main routed-expert layers. W4A16 NVFP4 applies to MTP experts
and 27 vision projections. In this image, automatic MoE selection on SM110
chooses **vLLM CUTLASS** for the main experts and **Marlin** for MTP. FlashInfer
CUTLASS is a different backend and is explicitly excluded for SM110 by vLLM's
selector; its earlier primitive probe must not be presented as model-level
coverage. Keep automatic selection so the two quantization schemes can choose
different backends.

Actual-shape primitive probes used 512 experts, hidden size 2560, intermediate
size 640 and top-k 10, with both one and eight input tokens. The vLLM CUTLASS
W4A4 path produced nonzero output within 4% of the ideal BF16 constant-weight
reference. Marlin's real weight repacking and scale conversion followed by
W4A16 execution matched its representable constant reference. Marlin conversion
peaked at 5.91 GiB of Torch memory for this single-layer test, which must be
allowed for during loading. These are controlled operator checks, not a
measurement of real-checkpoint quality, model routing or MTP acceptance.

## Checkpoint loading and padding failure

The complete checkpoint downloaded successfully (about 98.57 GiB), and its
26.82 GiB packed PLE table passed metadata and size checks. Three full startup
attempts loaded the weights (70.83 GiB reported by vLLM) and attached the PLE
CPU worker, but none reached a healthy API. These attempts used BF16 KV,
4096-token context, a 512-token prefill limit, one sequence, no MTP and no
CUDA graphs. The first two failed during dummy profiling with CUDA illegal
memory access in the native CUTLASS MoE path. A third, instrumented run
synchronized successfully at MoE entry and found all 512-by-10 expert IDs
equal to `-1`, with finite zero activations and uniform routing weights.
An assertion stopped that run before metadata generation. Exact-image source
inspection found that the V2 dummy batch marks every token as padding, and
`VLLM_MOE_SKIP_PADDING=1` (the default) passes that mask to the router. A small
router A/B reproduced all `-1` IDs with the default and valid IDs with
`VLLM_MOE_SKIP_PADDING=0`; in a mixed batch, real tokens retained identical
expert IDs and weights. A fourth full startup with this optimization disabled
passed metadata generation, row shuffling, activation quantization and both
MoE GEMMs, then reached KV cache initialization. The workaround computes
padding tokens rather than rewriting invalid IDs. This is
not evidence that SM110 cannot execute NVFP4. Independent 512-token
probes passed both distributed routing and routing concentrated on ten
experts. A real-shape GDN prefill probe also passed its controlled reference.

## Memory allocation stall

The first load emitted recoverable NVIDIA allocation warnings; the second
reproduced the CUDA failure without those warnings. Linux reclaimed file
cache under memory pressure during loading. No kernel OOM kill was observed,
and memory pressure alone has not been established as the CUDA failure's
cause. A separate allocation stall appeared after the fourth run budgeted
9.18 GiB for KV: a live worker stack showed NVIDIA system-page allocation
inside direct compaction and page migration. Despite roughly 33 GiB free,
the Normal zone had no free buddy blocks of order 9 or larger (2 MiB on this
4 KiB-page kernel). Cgroup OOM and limit counters were zero. Stopping the
container restored high-order free blocks. A fifth trial explicitly limited
KV to 1 GiB, retained 4096-token context and removed synchronous CUDA debugging
and diagnostic instrumentation. It allocated capacity for 14,199 KV tokens,
completed warmup and served a healthy API. This avoids the observed allocation
stall but is not a controlled proof that KV size was the only contributing
factor.

## Eager generation baseline

Initial sequential smoke requests generated coherent Chinese (101 output
tokens), Python code (256 tokens, truncated by the request limit) and the
exact requested JSON object (20 tokens). Decode rates were 5.90–6.01 tokens/s;
time to first content was 2.41, 2.09 and 0.41 seconds respectively. The first
request triggered QSA JIT compilation. These are short functional probes with
BF16 KV, one request, no CUDA graphs and no MTP, not tuned benchmark medians.
Decode rate here is `(completion_tokens - 1) / (stream_end - first_content)`.

A warm repeat raised the code output limit to 512 tokens. All three requests
finished normally: Chinese 108 tokens at 5.99 tokens/s, code 341 at 5.99, and
JSON 20 at 5.92. First-content latencies were 0.44, 0.55 and 0.61 seconds.
The complete Python response parsed successfully and included three assertions
(not executed); it still used a Markdown fence despite the code-only prompt.
JSON again matched the exact requested object. This establishes basic text
generation, not a general quality evaluation or strict instruction-following
pass.

## Baseline launch configuration

The working baseline keeps the upstream PLE mmap/CPU-offload and MXFP8 patches,
the Thor QSA selector workaround, `VLLM_USE_V2_MODEL_RUNNER=1`,
`VLLM_PLE_CPU_OFFLOAD=1` and `VLLM_MOE_SKIP_PADDING=0`. Its principal serving
arguments are:

```sh
--tensor-parallel-size 1 --distributed-executor-backend mp \
--kv-cache-memory-bytes 1073741824 --max-model-len 4096 \
--max-num-seqs 1 --max-num-batched-tokens 512 \
--kv-cache-dtype bfloat16 --mamba-ssm-cache-dtype bfloat16 \
--load-format safetensors --safetensors-load-strategy lazy \
--enable-chunked-prefill \
--compilation-config '{"mode":0,"cudagraph_mode":"NONE"}'
```

## Decode CUDA Graph comparison

An isolated decode-graph follow-up changed only the compilation configuration
to `{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1]}`.
The image captured one graph in about three seconds, using 0.12 GiB; prefill
remained eager and Torch compilation stayed disabled. Chinese, complete Python
and exact JSON smoke responses succeeded. After a separate 32-token warmup,
three sequential 128-token generations of the same Chinese prompt measured:

| Configuration | Decode rates (tokens/s) | Median |
| --- | --- | --- |
| Eager, BF16 KV | 6.03, 6.08, 6.18 | 6.08 |
| Decode graph, BF16 KV | 26.31, 26.29, 26.41 | 26.31 |

This is a 4.32x improvement for this short single-stream workload, with MTP
still disabled. Requests used temperature zero and `ignore_eos=true` to keep
output length fixed; prefix caching remained enabled in both runs. Median
first-content latency was about 0.41 seconds in both. Different smoke prompts
produced appropriate different responses, but exact output equivalence was
not asserted. V2 has no built-in replay counter in this image; capture was
logged, while a profiler trace of replay has not been collected.

## MTP: missing GDN kernel and targeted fallback

An initial MTP trial kept BF16 KV and full vocabulary, set
`num_speculative_tokens=1` and graph capture size `[2]`. Automatic selection
used native CUTLASS for the target and Marlin for the W4A16 draft. Both models
loaded (72.36 GiB reported total), but warmup failed in
`fused_gdn_decode_post_conv_mtp` with `no kernel image is available for execution
on the device`. This is a separate multi-token GDN path, not the successful
ordinary decode path. The image's dispatch guard checks capability >=80 and
operator existence, which is insufficient to establish binary coverage for
Thor. `cuobjdump` of the exact library confirmed this kernel only in
SM80/86/89/90a/100f/120f code, with no SM110/110f version or matching PTX entry.
Other kernels in the same library do include SM110/110f. Adding
`and not current_platform.is_device_capability_family(110)` to
`_can_use_fused_gdn_mtp_decode` selects the existing speculative Triton/FLA
path only on Thor; globally forcing `VLLM_GDN_DECODE_KERNEL=triton` would also
change ordinary single-token decode. A two-token, actual-head-shape probe
passed convolution, recurrent state updates and gated RMS normalization against
a Torch reference in eager and graph modes. Output maximum error was 0.00768
after BF16 normalization, and per-token state error was at most 0.000244.
Graph replay with changed inputs also passed. A follow-up with nonzero history
and accepted-token counts of one and two checked selection of different prior
states, exact convolution-buffer sliding updates and unchanged null slots in
both eager and graph modes. These tests use valid state slots (slot zero is
reserved).

## MTP K1: full-model results

The targeted guard then passed full-model MTP startup and graph capture.
The same 1 GiB KV budget provided 10,132 tokens with MTP enabled. Keeping the
full draft vocabulary, K1 and capture size `[2]`, the identical fixed-length
benchmark measured **32.23, 32.79 and 33.59 tokens/s**, median **32.79**. This
is 24.6% above the non-speculative graph baseline and 5.39x the original eager
baseline. Median first-content latency was 0.47 seconds. Prometheus counter
deltas over the 32-token warmup plus three 128-token requests showed 170 of
245 proposed tokens accepted (69.4%); this acceptance figure includes warmup,
whereas the reported timing median excludes it.

Warm functional checks produced coherent Chinese at 32.99 tokens/s, complete
Python at 38.24 and exact JSON at 37.35. Python parsed and included three
assertions, which were not executed. Rates vary with the generated content
and draft acceptance. Full-model output equivalence, long-context quality and
multimodal MTP remain unverified. This working experiment adds the targeted
GDN guard and these arguments to the BF16 baseline:

```sh
--speculative-config '{"method":"mtp","num_speculative_tokens":1}' \
--compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[2]}'
```

## MTP K3: comparison with K1

Before the full-model trial, the GDN fallback probe was extended to four
tokens and accepted-token counts 1–4 with nonzero history. All eight
eager/graph cases passed output, per-token state and exact convolution-buffer
writeback checks. Peak tensor allocation was 67.26 MiB. K3 then loaded and
served successfully with the same SM110 guard, BF16 KV and full vocabulary:

```sh
--speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
--compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,4]}'
```

Capture size 4 covers target verification/first draft; size 1 covers subsequent
single-token draft steps. Logs confirmed target and both speculator captures.
Model loading still reported 72.36 GiB, while the 1 GiB KV budget provided
7,404 tokens, sufficient for the configured 4096-token single request.

A fresh K1 sweep immediately preceded the K3 run on 2026-09-13. Each workload
used its own warmup (32 tokens for prose/code, one complete JSON response),
then three sequential measured requests. Prefix caching stayed enabled,
temperature was zero and thinking was disabled. Prose/code used
`ignore_eos=true`; JSON used ordinary stopping with an 80-token cap. Fixed
lengths and JSON values were verified. Exact prompts:

| Workload | Output tokens | Prompt |
| --- | ---: | --- |
| Chinese | 128 | 请写一篇详细的科普文章，解释地球水循环如何连接海洋、大气、陆地和地下水，并讨论人类活动的影响。 |
| Code | 256 | Write a Python function that merges overlapping integer intervals. Include type hints and three assert examples. Output only code. |
| JSON | 20 | 仅输出一个JSON对象，包含city值北京，country值中国，number值42，不要Markdown。 |

| Workload | K1 decode rates | K3 decode rates | Median change |
| --- | --- | --- | --- |
| Chinese | 33.91, 33.83, 33.99 | 31.39, 31.79, 31.74 | 33.91 → 31.74 tokens/s (−6.4%) |
| Code | 38.96, 38.65, 38.27 | 52.72, 53.60, 53.61 | 38.65 → 53.60 tokens/s (+38.7%) |
| JSON | 37.17, 36.93, 36.90 | 45.21, 45.12, 45.74 | 36.93 → 45.21 tokens/s (+22.4%) |

Median first-content latencies for Chinese/code/JSON were 0.463/0.492/0.481
seconds with K1 and 0.484/0.491/0.517 with K3. The same streaming decode
estimate is used throughout; short JSON timings are not a sustained-throughput
benchmark. Prometheus deltas over each three-request group, excluding warmup:

| Workload | K1 accepted / proposed | K3 accepted / proposed | Mean accepted length, K1 → K3 |
| --- | --- | --- | --- |
| Chinese | 159/225 (70.7%) | 213/522 (40.8%) | 1.71 → 2.22 |
| Code | 372/393 (94.7%) | 561/612 (91.7%) | 1.95 → 3.75 |
| JSON | 30/30 (100%) | 48/54 (88.9%) | 2.00 → 3.67 |

Mean accepted length is `1 + accepted_tokens / draft_steps`, including the
bonus token. Proposal accounting can include tokens beyond a request's stop
boundary; it is not identical to delivered output-token counts. These results
support K3 for the measured code workload, while K1 was faster for this prose
prompt. They do not establish a universal best setting or isolate acceptance
from changes in the generated text.

A separate warm functional pass generated complete Python (277 tokens,
53.54 tokens/s), which parsed and included three assertions (not executed).
Chinese was coherent and JSON exactly matched the requested object. The
experimental service was left running K3; the working K1 configuration and
both sets of raw results were retained outside the public repository.

## Deterministic QSA selection: correctness regression

On 2026-09-13, synthetic inputs reproduced incorrect `persistent_topk`
selection on this Thor. With `k=512`, 64 rows of 4096 float32 scores drawn
from a narrow distribution (mean 10, standard deviation 0.03) selected
strictly smaller values than the exact top-k in all ten repetitions. The
maximum selected-value error was 0.0396233. A 33-row, 32768-column case also
failed. These are value errors, distinct from choosing different indices
with equal scores. All tested shapes changed output order across repeated
calls; tied-cutoff cases also changed the selected index set. This does not
establish that earlier model responses were wrong.

The standalone deterministic kernel from
[jschmied's pinned sources](https://github.com/jschmied/qwen38-flash-next-gb10/tree/e0ef69d4f5575dad00d34e05479eaf4c6547bace/patches/kernel-det)
was built for `sm_110a` in the existing Torch 2.13.0 / CUDA 13.0 image.
Source hashes were checked against the
[Saren build recipe](https://github.com/Saren-Arterius/qwen3.8-Flash-DGX-AutoRound).
Only SM110 QSA selector dispatch was changed; the current attention/scales
interfaces, model weights and GDN fallback were retained.

Validation passed:

- Twenty shape/distribution cases, ten repetitions each: exact selected
  values, valid unique indices, stable output order and stable index sets.
- Six CUDA Graph shapes, `k=512/1024/2048`, with changing visible lengths,
  including short and empty sequences.
- Integrated QSA score, selection and sparse-attention reference checks.
- A 2823-token retrieval prompt returned the exact requested JSON in three
  consecutive requests, including prefix reuse. This is a targeted regression,
  not a broad long-context quality evaluation.

The same K3 workload/warmup protocol above produced these three-run medians:

| Workload | Before fix | Deterministic selector |
| --- | ---: | ---: |
| Chinese | 31.74 | 32.02 tokens/s |
| Code | 53.60 | 54.21 tokens/s |
| JSON | 45.21 | 45.53 tokens/s |

All nine measured response texts matched the previous run exactly; JSON was
correct. The small timing differences do not establish a speedup. This is a
correctness improvement with broadly unchanged measured throughput. The
experimental service now uses the deterministic selector; the previous
launch configuration remains available for rollback.

Related upstream reports:
[persistent_topk candidate loss #51782](https://github.com/vllm-project/vllm/issues/51782)
and [deterministic selection PR #55122](https://github.com/vllm-project/vllm/pull/55122).

## Official Thor image: initialization memory

The [NVIDIA Thor recipe](https://www.jetson-ai-lab.com/models/qwen3-8-flash-next/)
was tested with image digest
`sha256:512bf772c7ef221df1a66ab9c95546d77daeba6ba61723692852e6eb0cae7526`.
Its packed NVFP4 PLE table stays on the GPU; the existing experimental runtime
uses CPU mmap/offload. All 37 safetensors files in the recipe's
`local-inference-lab/Qwen3.8-Flash-Next-NVFP4` revision
`ada4da32a583a78aa47299f45a70603c950490b8` matched the existing Mia checkpoint
by SHA-256 and size, so the tests reused those weights.

Three initialization attempts retained a 4096-token context, 1 GiB BF16 KV,
BF16 Mamba state, one request and K3 MTP. These first probes used eager mode.
They were stopped by the experimental memory watchdog before a healthy API
was available; no official-image throughput result was obtained.

- The first attempt crossed the low-free-memory guard while loading PLE.
- Text-only loading plus `POSIX_FADV_DONTNEED` advice on read-only checkpoint
  files reduced reclaimable file-cache pressure. It reached the final model
  loading report of 98.4 GiB, but available host memory fell below the retained
  12 GiB margin and the watchdog stopped it.
- A third attempt added GC and CUDA cache release between target and MTP
  loading. Target allocated/reserved memory was unchanged at that point,
  and the available-memory guard still stopped initialization.

All three reported `OOMKilled=false`; watchdog termination is not evidence
of a CUDA or kernel OOM, nor proof that the official configuration cannot fit.
One NVIDIA memory error was recorded in the second attempt, none in the first
or third. The official image has not yet met this experiment's memory margin.
Its source already shares target/draft token embeddings and output heads;
different model paths alone do not establish duplicate resident weights.

## Native SM110 GDN MTP backport

The native GDN MTP kernel from the official image's vLLM revision
`385dce36b` was built as a separate `sm_110f` extension in the existing
CPU-offload runtime. Only MTP GDN dispatch changed; deterministic QSA,
weights, packed CPU PLE, BF16 caches and K3 settings were retained.
The service log confirmed native-kernel execution and successful CUDA Graph
capture. Model loading still reported 72.36 GiB.

The extension passed 32 targeted cases against the bundled FLA/RMSNorm
reference: eager and CUDA Graph execution, both supported gate activations,
changing inputs, and a sequence of accepted-token histories from one to four.
Output relative L2 error stayed below `5e-4`; state checks used `atol=rtol=0.03`.
These are tolerance-based checks, not bitwise equivalence or model-quality
certification.

The same three-run K3 protocol produced:

| Workload | FLA fallback + deterministic QSA | Native GDN + deterministic QSA |
| --- | ---: | ---: |
| Chinese | 32.02 | 33.56 tokens/s |
| Code | 54.21 | 54.92 tokens/s |
| JSON | 45.53 | 45.73 tokens/s |

Chinese and code response texts changed across implementations, although
each implementation was stable across its own three measured repetitions.
JSON remained identical and correct. Consequently the small differences
above do not isolate kernel speed: generated tokens and speculative
acceptance can also change. This did not reproduce a large end-to-end gain.
The 2823-token retrieval check also passed three times with the native kernel.
A code smoke test with normal EOS handling completed within a 512-token budget; its
three assertions and three additional empty/unsorted/negative-interval checks
passed. This small smoke test does not measure general coding quality.
The experimental service now uses the native extension, with the FLA launch
configuration retained for rollback.

## Graph-enabled profiling

The native-GDN runtime was restarted with on-demand Torch profiling, retaining
K3 and CUDA Graphs. Sampling was off for the repeated baseline: Chinese
33.92, code 56.19 and JSON 45.77 tokens/s; all nine measured texts matched the
previous native-GDN run. These small timing changes do not establish a gain.

Separate Chinese and code traces each contained one context iteration and
nine decode iterations. Although a two-iteration delay was configured, it
did not exclude the context iteration; analysis used the observed boundaries.
Actual Graph replay was verified from 38 `cudaGraphLaunch` calls per trace,
graph IDs and launch correlations. CPU annotation durations alone do not
cover the full asynchronous sampling/drafting cycle.

| Observed decode component | Chinese | Code |
| --- | ---: | ---: |
| Target Graph GPU span, median of 9 | 42.67 ms | 41.74 ms |
| Three draft Graph spans combined, median of 9 | 17.73 ms | 17.70 ms |
| Target start to final draft completion, median of 9 | 65.41 ms | 64.94 ms |
| Successive target-start interval, median of 8 | 72.12 ms | 73.53 ms |

The complete vocabulary head remains BF16 with shape `[248320,2560]`.
An independent synthetic-weight probe of that exact shape measured roughly
4.75 ms for one row and 4.77 ms for four rows. It identified the cuBLAS kernel
`nvjet_sm110_tst_128x8_64x12_2x1_v_bz_TNT` with grid `[1940,1,1]`;
the same kernel name with a smaller grid also occurs in other layers.
Matching both name and grid found exactly four head projections per captured
iteration, averaging about 19.1–19.2 ms combined. Three are already included
in the draft Graph spans above; adding them again would double-count time.
The 36 native GDN kernels together consumed about 1.10 ms per decode iteration.
This points to the full-vocabulary head as a substantially larger remaining
cost than GDN in this configuration. It does not establish the speed or
quality of a quantized-head replacement.

The currently mounted PLE patch waits on the host for the CPU worker to finish
its H2D copy before replay. Its GPU wait wrapper is a no-op. The CPU worker is
not captured by the main worker's Torch profiler, so these traces do not
isolate PLE lookup or host-wait time. Residual gaps also include scheduling,
launch and profiler overhead; they must not all be assigned to PLE. Likewise,
target kernels overlap across streams, so summed kernel time can exceed the
Graph's elapsed span.

Profiling was stopped after capture and the API remained healthy. Raw traces
stay outside Git. Reduced-vocabulary drafting remains disabled; these results
do not change its unvalidated language-coverage and acceptance tradeoff.

## Serving status

FP8 KV remains a separate capacity/quality experiment. It is not needed for
the current 4096-token single-request tests; the upstream recipe itself
reports a long-reasoning quality regression with FP8 KV, so retain BF16
while isolating speculative-decoding performance.
The initial API is an experimental loopback-only container, not a persistent
fleet inference service.

Probe scripts and detailed results remain outside the public repository.

## External comparison

The Flash Next repository reports approximately 48.7 tokens/s for one stream
and 162.9 aggregate for eight streams, whereas the author's separate adaptation
report gives different workloads/settings. These are Spark measurements, not
directly comparable single-Thor results.

## References

- [Qwen3.8 Flash Next Spark deployment at the reviewed revision](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark/tree/d03809008834124e80223c3482f2ddb59577a48f)
- [Author's DFlash2 single-stream 125–133 TPS report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
