# Huihui Qwen3.8-27B: NVFP4 trial and DFlash2 profiling

[Thor overview](../../thor.md)

Trial: 2026-09-12.

The abliterated checkpoint
`Vtuber-plan/Huihui-Qwen3.8-27B-abliterated-NVFP4` was tested at revision
`43aa7ff5eef05ab50a3bfa6aca581085312c7a04`. Both ordinary decoding and DFlash2
loaded successfully on Thor, using the same pinned image, draft, and common
server settings as the [original-model retest](qwen3.8-27b.md#retained-experimental-configuration). The target adds `--quantization modelopt` and
`--tool-call-parser qwen3_coder`. The loader reported `modelopt_fp4`, NVFP4,
and 19.70 GiB of weight memory usage. KV cache remained BF16 despite the
checkpoint also providing FP8 cache scales.

The same three prompts, token caps, cache flushes, warmups, three measured
rounds, and streaming decode calculation were used. Requests explicitly set
`enable_thinking=false` and `reasoning_effort=medium`. The original model
service was stopped for these measurements, and downloads had finished.
Spot checks showed approximately 92–93% CPU idle, zero I/O wait, and no swap
usage; these were not continuous telemetry recordings.

| Target and configuration | Chinese | Short code | Long code |
| --- | ---: | ---: | ---: |
| Original NVFP4, no speculation (earlier retest) | 13.04 | 13.04 | 13.01 |
| Huihui NVFP4, no speculation | 15.24 | 15.24 | 15.19 |
| Original NVFP4, DFlash2 (earlier retest) | 20.50 | 44.95 | 55.92 |
| Huihui NVFP4, DFlash2 | 19.36 | 62.26 | 58.78 |

These results do not isolate the effect of abliteration: the checkpoints also
differ in quantization/export details, chat templates, and generated text. The
Huihui trial explicitly selected medium reasoning effort, whereas the earlier
original throughput requests only disabled thinking. Its model card documents
a modified chat template. Faster decoding cannot therefore be attributed to
removing refusals alone.

With DFlash2, Huihui improved short-code throughput by about 39% and long-code
throughput by 5%, while Chinese throughput fell by 6%. Sample scheduler windows
reported accepted lengths around 1.8–2.0 for Chinese and 5.7 for long code;
these are illustrative windows, not full-run averages. The draft remained
useful with the modified target, but its benefit depended strongly on workload.

The original checkpoint was already well below the externally reported
125–133 tokens/s, and switching to Huihui did not close that gap. Thus this
particular abliterated checkpoint does not explain the pre-existing gap.
This is not a reproduction of the external benchmark: its exact prompts,
token accounting, model revisions, and complete runtime configuration have
not been matched locally.

## Capability smoke checks and retained state

Both Huihui configurations passed small checks for Chinese instructions,
strict JSON values, structured tool-call arguments, and thinking on/off.
Tools were not executed. These checks are not an evaluation of refusal rates,
general model quality, or long-context reliability.

An interval-merging prompt exposed ambiguity over adjacent integer intervals;
both original and Huihui outputs initially failed two of six functional cases.
After explicitly requiring overlap or a shared endpoint, the Huihui outputs
with and without DFlash2 passed all six cases after removing Markdown fences.
They still violated the instruction to omit those fences. The original service
did not have a tool-call parser enabled, so its missing structured tool-call
fields are not evidence of inferior model capability.

The original service was restored after timing. The Huihui DFlash2 trial was
retained on a separate loopback port; both health checks returned HTTP 200.
Serving is still experimental and not configured for automatic startup.
Pinned launch scripts, raw responses, benchmark rounds, and server logs were
retained outside the public repository.

## Proposed follow-ups after the trial

1. Align the comparison protocol: obtain the external deployment's exact
   target/draft revisions, image and launch arguments, prompts, thinking mode,
   output lengths, and definition of TPS. Locally record TTFT, end-to-end TPS,
   decode TPS, and accepted tokens per verification step separately. Do not
   compare eight-request aggregate throughput to a single stream.
2. Profile one fixed target and workload to separate draft, target verification,
   and host scheduling time. Record actual GPU/EMC clocks, power and thermal
   limits alongside the trace. This should distinguish poor draft acceptance
   from expensive verification or scheduling; neither is established as the
   dominant cause yet.
3. Test longer English and Chinese code generation with the same target and
   explicit template settings, increasing the context budget as needed and
   reporting it. Pair this with less predictable prose. Keep token counts and
   acceptance statistics, rather than selecting only the fastest prompt.
4. Use those measurements to choose one runtime change at a time: a compatible
   SGLang/kernel revision, backend, or supported speculation setting. Full-model
   FA4 and DFlash2 with `torch.compile` already failed in this image; retry them
   only with evidence that the specific failure has been addressed.

## DFlash2 profiling and output projection follow-up

Two short Huihui + DFlash2 profiles captured eleven early speculative decode
iterations each, excluding prefill. CUDA graph IDs and launch correlations
separate draft from target verification; the annotation names alone do not.

| Median GPU span per speculative iteration | Chinese | Long code |
| --- | ---: | ---: |
| Entire iteration | 95.43 ms | 97.50 ms |
| Draft graph | 23.36 ms | 23.70 ms |
| Target verification graph | 69.67 ms | 71.31 ms |

Adjacent iteration intervals closely matched these GPU spans. CPU event
synchronization was mostly waiting for the GPU, rather than extra computation.
The sampled workload was dominated by matrix operations: about 97% of draft
kernel time was BF16 GEMM/reduction, while target kernel time was approximately
76% NVFP4 GEMM and 14% BF16 GEMM/reduction. Kernel sums can overlap and must not
be treated as additive wall-time components. GPU clocks stayed around
1385–1386 MHz and EMC at 4266 MHz, with GPU temperatures below 56 C. These
observations do not establish memory-bandwidth saturation or an absolute
throughput ceiling; profiler overhead was not calibrated.

Both graphs contained a roughly 9.75 ms BF16 projection with grid `(1940,1,1)`.
The output vocabulary has 248320 entries, exactly 1940 blocks of 128. A separate
CUDA graph microbenchmark on Thor reproduced the same full-vocabulary kernel,
`nvjet_sm110_tst_128x8_64x12_2x1_v_bz_TNT`, using hidden size 5120:

| Vocabulary entries | BF16 head size | 7 rows | 8 rows |
| --- | ---: | ---: | ---: |
| 248320 | 2.368 GiB | 9.676 ms | 9.669 ms |
| 65536 | 0.625 GiB | 2.556 ms | 2.555 ms |
| 32768 | 0.313 GiB | 1.339 ms | 1.337 ms |

The standalone test used Torch 2.13.0+cu130, five eager warmups, five graph
warmups and twenty CUDA-event measurements per shape, with only one head
allocated at a time. GPU frequency was 1386 MHz and temperature 34–35 C.
This strongly supports the output-head attribution, but does not add missing
shape/module labels to the original trace retroactively.

A draft-only reduced vocabulary is therefore a concrete next experiment.
It must use a separate head and map sampled IDs back to the original vocabulary;
the target's complete output head and verification must remain intact. First
measure greedy decoding with Chinese, English and code prompts, recording
acceptance and total iteration time. The microbenchmark does not measure those
outcomes. Even eliminating the entire draft projection would save only about
10 ms of a 97 ms profiled iteration, roughly an 11% idealized throughput gain;
it cannot by itself explain the gap to the external 125–133 tokens/s report.

## References

- [Original SGLang deployment reference for DGX Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — adapted and measured on Thor; its Spark CPU affinity and attention settings are not directly transferable.
- [Author's DFlash2 single-stream 125–133 TPS report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
- [Huihui NVFP4 checkpoint and model card at the tested revision](https://huggingface.co/Vtuber-plan/Huihui-Qwen3.8-27B-abliterated-NVFP4/tree/43aa7ff5eef05ab50a3bfa6aca581085312c7a04)
