# Qwen3.8 Flash Next: Lazycat app deployment and benchmark

[Thor overview](../../thor.md) ·
[Earlier local adaptation experiments](qwen3.8-flash-next.md)

Inspection and trial: 2026-09-18. This records the official Lazycat app and
prebuilt compute-capsule runtime on one Thor T5000. It is separate from the
earlier locally assembled low-context K1/K3 experiments.

Tested versions:

- AI Pod: `2.2.4-nightly.20260917081204+43444c8`;
- Lazycat compute-capsule firmware (`算力舱固件`):
  `2.2.4-nightly.20260917081206+43444c8`;
- Lazycat Qwen 3.8 Flash Next app/LPK: `0.1.40`; and
- compute runtime: `runtime-134-0.1.6`.

The compute-capsule control panel set the fan profile to Performance
(`风扇-性能模式`). Private addresses, hostnames, user and device identifiers are
omitted.

## Lazycat management app

The installed package is `cloud.lazycat.aipod.qwen38-flash-next`, displayed as
“Qwen 3.8 Flash Next 未审查版”. Its package description advertises a default of
eight scheduled requests and 265K context, with context support from 128K
through 320K. The inspected persisted deployment was:

- model ID `qwen-3.8-flash-next-uncensored` and model version `0.1.40`;
- mode `multi-concurrency`, requested concurrency 8 and `maxNumSeqs` 8;
- context length 265,000;
- estimated device memory 112 GiB; and
- runtime image
  `registry.lazycat.cloud/catdogai/qwen38-flash-next:runtime-134-0.1.6`.

The original LPK SHA-256 is
`7b273c0dddbbec9630caee5172ee97ea61746f474d0f2d6203bbd9de002f23cf`.
Its embedded management image is pinned by digest
`sha256:b4e7182dca6a9da68d842217cb3bc18c91a940f52c872c79fa7b26d28f9c2894`.

The current restart record reported 367.66 seconds from service start through
ready. The first installation also had to transfer and import a 142.75 GB
runtime archive; that one-time transfer is not part of the restart figure.

## Compute runtime

The ARM64 runtime image has digest
`sha256:f028c1b7ce2c6951c17d38fd2a20b4031971b5cea8ff3b31b99d41690325ce87`,
creation date 2026-09-06 and local image size 142.75 GB. Its labels identify
vLLM revision `18f658bb3185779ee58999a328246d09886d568b` and checkpoint
`gorbatjovy/qwen3.8-flash-next-abliterated-NVFP4-plefp8` revision
`2065365912e46b205c64a70ac5b85b4869674d31`.

Observed software versions:

| Component | Version |
| --- | --- |
| Python | 3.12.13 |
| Torch | 2.11.0 |
| vLLM | `0.0.0+18f658bb3185` |
| FlashInfer | 0.6.18 |
| Triton | 3.6.0 |
| Transformers | 5.12.1 |
| Humming native kernels | 0.1.13 |

The image contains 17 indexed weight files totaling 125.90 GiB. The PLE table
accounts for 47.7 GiB on disk and is memory-mapped as 128 FP8 shards using 32
CPU workers, pinned staging buffers and no full prewarm. vLLM reported 78.67
GiB for the loaded target and draft models. The complete model-loading phase
took 233.94 seconds on the observed restart; graph and engine initialization
then took 22.80 seconds, followed by multimodal and request-shape warmups.

The original checkpoint has a native 262,144-token context. The runtime builds
a 320,000-token YaRN view with factor 1.220703125, but this deployment serves a
hard maximum of 265,000 total input and output tokens.

Principal serving configuration:

| Setting | Observed value |
| --- | --- |
| Scheduler | 8 sequences, 8,704 batched tokens |
| KV cache | 12.8 GiB, 351,829-token capacity |
| Prefix cache | Disabled |
| Speculative decoding | One MTP layer, K16 |
| CUDA Graph | Full decode only, capture sizes 1 and 17 |
| Mamba state | BF16 |
| GDN MTP decode | Triton fallback |
| PLE | FP8 mmap, pinned staging, 2,048-row chunks |
| Networking / IPC | Host mode / host IPC |
| Container privileges | NVIDIA runtime, `IPC_LOCK`, non-privileged root |

The reported KV capacity corresponds to only 1.33 simultaneous full
265,000-token requests. “Eight concurrent” is therefore a scheduler maximum
for shorter requests, not capacity for eight maximum-context requests.

The target checkpoint uses ModelOpt W4A16 NVFP4. The runtime selected Marlin
for its NVFP4 MoE path on SM110 and installed a custom NVFP4 CUTLASS
full-vocabulary head. Both the FP8 and FP4 head switches are set, but the
patch's conversion and dispatch code gives FP4 precedence; the startup log
confirmed the NVFP4 candidate. It also uses a Triton GDN fallback because the
native multi-token GDN operator is absent.

The profile and environment request cooperative-top-k disablement through
`VLLM_QWEN4_DISABLE_COOP_TOPK=1`. However, this vLLM build reports that variable
as unknown, the installed sparse-indexer source does not read it, and its SM110
selector condition remains present. Consequently, the intended disablement
cannot be treated as active without an execution trace. This is distinct from
the deterministic-selector patch validated in the
[earlier local experiments](qwen3.8-flash-next.md#deterministic-qsa-selection-correctness-regression).

## API and capability observations

The service exposes the standard vLLM OpenAI-compatible chat, completions,
responses, tokenization and metrics routes. It starts without an API-key
argument: model-list requests with no authorization, an incorrect bearer token
and the configured token all returned HTTP 200. It also has no TLS on the
model process. Network access control must therefore be provided externally.

The Lazycat client configuration advertises text and image input, reasoning,
16,384 output tokens and sampling defaults temperature 0.3, top-p 0.95 and
top-k 20. The runtime enables the Qwen3 tool-call and reasoning parsers. Tool
calling and reasoning quality were not evaluated in this pass.

A multimodal smoke request used an in-memory 32 x 32 solid-red PNG and asked
for one lowercase color word. The model returned `red` in 9.205 seconds. The
request used 95 prompt and two completion tokens. This confirms the target
vision path, not broad visual quality. The first real image request triggered
two additional Triton JIT compilations, so startup warmup did not cover that
actual image shape. The MTP log also states that external multimodal embeddings
are not passed to the draft model; multimodal requests use text-only draft
inputs.

## Single-stream measurements

The three workloads and timing definition match the earlier local experiments.
Each workload had one unreported warmup followed by three sequential measured
requests. Temperature was zero, thinking was disabled and a fixed seed was
provided. Chinese and code used fixed output lengths; JSON used ordinary stop
handling. Decode rate is `(completion tokens - 1) / (stream end - first
content)`.

| Workload | Output tokens | Decode rates | Median | Median first-content latency | MTP accepted / proposed |
| --- | ---: | --- | ---: | ---: | ---: |
| Chinese | 128 | 18.52, 18.71, 19.85 | 18.71 tokens/s | 0.318 s | 244 / 2,496 (9.8%) |
| Code | 256 | 58.66, 61.09, 53.04 | 58.66 tokens/s | 0.305 s | 676 / 1,616 (41.8%) |
| JSON | 15, 15, 20 | 53.76, 53.64, 71.71 | 53.76 tokens/s | 0.323 s | 49 / 96 (51.0%) |

The fixed 256-token code throughput requests ended at the length limit and
were syntactically incomplete. A separate normal-stop request with a 512-token
budget completed after 287 output tokens in 5.14 seconds. Removing its
Markdown fence produced valid Python with the requested three assertions;
the assertions were not executed.

All three JSON responses parsed to the exact requested values. Short-response
decode rates are highly sensitive to streaming and stop timing and should not
be interpreted as sustained throughput.

Despite temperature zero and a fixed seed, the three measured Chinese
responses had three different hashes, code had three and JSON had two. The
observed non-determinism is compatible with several batching, QSA and
speculative-sampling paths; it is not by itself proof of a single cause. The
ineffective top-k environment switch above is nevertheless a configuration
issue worth isolating.

The manufacturer's product-page single-stream range is 59–116 tokens/s. The
code median is near its lower bound, while the Chinese prompt is well below
it because K16 acceptance was only 9.8%. Prompt, generated text and acceptance
strongly affect speculative-decoding speed, so the product range is not a
single guaranteed rate.

## Eight-request concurrency

One warmup batch preceded three measured batches. Each batch submitted eight
simultaneous copies of the code workload with 128 output tokens; prefix caching
was disabled by the server. Aggregate decode rate counts all delivered tokens
from the first content event through the final stream completion.

| Batch | Aggregate decode | Batch wall time | Per-request decode median | Per-request TTFC median |
| --- | ---: | ---: | ---: | ---: |
| 1 | 138.43 tokens/s | 8.80 s | 37.39 tokens/s | 3.34 s |
| 2 | 125.95 tokens/s | 8.61 s | 35.24 tokens/s | 2.44 s |
| 3 | 135.84 tokens/s | 8.01 s | 37.51 tokens/s | 2.35 s |

The aggregate median was 135.84 tokens/s and MTP accepted 2,855 of 6,000
proposed tokens (47.6%). This result falls within the product-page 108–313
tokens/s eight-request range. Individual TTFC ranged from 0.53 to 5.69 seconds
because the eight requests did not all enter the scheduler at once.

## Prefill and context capacity

Three post-warmup requests used an ordinary text prompt measured by the API as
5,001 tokens, followed by 32 output tokens. Prefix caching remained disabled.
End-to-end first-content latency was 2.862, 2.945 and 2.948 seconds, median
2.945 seconds. A separate request's Prometheus deltas reported 2.577 seconds
inside the prefill phase, or 1,940 computed tokens/s; queue time was about
31 microseconds.

The product page reports 2.5-second TTFT at 5K and 2,589 prefill tokens/s. The
local TTFT was about 17.8% slower and the internal prefill rate about 25.1%
lower. Exact text, tokenization, timing boundary and software build are not
known to match, so this is an observed comparison rather than a controlled
regression.

A near-limit request with 260,001 input tokens and one output token succeeded.
The complete HTTP request took 175.73 seconds; vLLM attributed 174.95 seconds
to prefill, or 1,486 computed tokens/s, with negligible queue time. The output
token did not produce non-empty streamed text, so this is not labeled TTFT.

During that request, 175 active one-second GPU samples averaged 97.71%
utilization and 49.74 W reported GPU power. Peak observed GPU power was 51.31 W
and peak temperature 59 C. These figures exclude whole-board power.

A constructed request exceeding the deployed window was rejected before
inference with HTTP 400 in 0.72 seconds. The error explicitly stated a maximum
total context of 265,000 tokens. Thus the internal 320K model view does not make
320K available through this deployment.

## Active-inference process snapshot

A root-level process snapshot was taken during a separate eight-request load.
At the capture point, vLLM reported four running requests, four waiting
requests and zero preemptions. All eight requests later completed with HTTP 200
at their 4,096-token limit; this load was used to hold the runtime active for
inspection, not as an additional performance result.

The Qwen container had five processes at that instant:

| Role | Process | Threads |
| --- | --- | ---: |
| Container init | `docker-init` | 1 |
| Runtime bootstrap and signal-forwarding wrapper | `bash` | 1 |
| vLLM OpenAI API frontend | `vllm.real serve` | 66 |
| Python multiprocessing resource tracker | `multiprocessing.resource_tracker` | 41 |
| Model execution process | `VLLM::EngineCore` | 134 |

The full host snapshot contained 484 processes and 1,279 threads. The private
capture also includes the complete root-visible command lines, executable
mappings, process tree, Docker process lists, cgroups, namespaces, sockets and
a contemporaneous `tegrastats` sample. Those raw files remain outside the
public repository because the whole-host lists contain environment-specific
identifiers and unrelated service command lines.

## Measurement status and follow-ups

This is sufficient as an initial version-pinned record of the official app,
single-stream behavior, eight-request scheduling, 5K prefill, multimodal smoke
and near-limit capacity. Useful follow-ups are:

1. Trace QSA selector execution and compare the shipped selector with the
   validated deterministic SM110 implementation.
2. Compare K1, K3 and K16 on the exact same output text or controlled token
   path; the current K16 result varies sharply with acceptance.
3. Test the app's 128K and 320K deployment choices separately rather than
   extrapolating from this 265K configuration.
4. Add structured tool-call and reasoning tests, plus a broader image set.
5. Capture whole-board power and fan RPM under single and concurrent decode.

Raw request metadata, counters and telemetry remain outside the public
repository.

## References

- [Earlier local Qwen3.8 Flash Next experiments](qwen3.8-flash-next.md)
- [Manufacturer-published performance snapshot](../../thor.md#manufacturer-published-performance-snapshot)
