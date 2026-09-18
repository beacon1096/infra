# Qwen3.8-27B: Lazycat app deployment and benchmark

[Thor overview](../../thor.md) ·
[Earlier local SGLang experiments](qwen3.8-27b.md)

Inspection and trial: 2026-09-18. This records the official Lazycat app and
prebuilt compute-capsule runtime on one Thor T5000. It is separate from the
earlier locally assembled SGLang deployments.

Tested versions:

- AI Pod: `2.2.4-nightly.20260917081204+43444c8`;
- Lazycat compute-capsule firmware (`算力舱固件`):
  `2.2.4-nightly.20260917081206+43444c8`;
- Lazycat Qwen 3.8 27B app/LPK: `0.1.58`;
- embedded management image: `0.1.57-amd64-v1`;
- deployed model version: `0.5.1`; and
- compute runtime: `runtime-160-0.2.2-modelopt-nvfp4-draft`.

The compute-capsule control panel set the fan profile to Performance
(`风扇-性能模式`). Private addresses, hostnames, credentials, user and device
identifiers are omitted.

## Lazycat management app

The installed package is `cloud.lazycat.aipod.qwen38-27b`, displayed as
“Qwen 3.8 27B 未审查版”. Its manifest uses management image
`registry.lazycat.cloud/catdogai/qwen38-27b-lpk:0.1.57-amd64-v1`; the package
metadata itself is one revision newer at 0.1.58.

The persisted deployment record reported:

- model ID `qwen-3.8-27b-uncensored` and model version `0.5.1`;
- mode `custom`, requested concurrency 8 and `maxNumSeqs` 8;
- context length 512,000;
- estimated device memory 76.5 GiB, with 43.4 GiB estimated remaining; and
- runtime image
  `registry.lazycat.cloud/catdogai/qwen38-27b:runtime-160-0.2.2-modelopt-nvfp4-draft`.

The observed restart completed in 120.43 seconds. The earlier first deployment
log spanned about 23 minutes 34 seconds and included transferring and importing
the runtime image. A subsequent restart reused the local image and a 43.1 MiB
warm-cache archive, so the two times are not comparable.

## Compute runtime

The ARM64 runtime image has digest
`sha256:5641d0ab6b2085572cae5080d80b6b624fc346af0228a2840bf785fbbfc75062`,
creation date 2026-09-15 and local image size 57.33 GiB. The deployment record's
disk estimate is 61.56 GB.

Its labels identify vLLM revision
`18f658bb3185779ee58999a328246d09886d568b` and DFlash2 revision
`3406ec1dae9916f920b90f0dbf90dcf54923d042`. The target is
`joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt` revision
`e5ff4986938dcd0dd05ab4cce89da1b052be6ce3`; the calibrated NVFP4 draft is
`maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal` revision
`bd7a934213c47a9e7ef69eef36bb3325f47fd1f1`.

Observed software versions:

| Component | Version |
| --- | --- |
| Python | 3.12 |
| Torch | 2.11.0 |
| vLLM | `0.0.0+18f658bb3185` |
| FlashInfer | 0.6.17 |
| Triton | 3.6.0 |
| Transformers | 5.12.1 |

The target weight file is 18.39 GiB, its grafted MTP file is 0.79 GiB and the
DFlash2 draft is 1.44 GiB. Both target and draft use ModelOpt NVFP4, with
CUTLASS selected as the target linear backend.

Principal serving configuration:

| Setting | Observed value |
| --- | --- |
| Scheduler | 8 sequences, 4,096 batched tokens, async scheduling disabled |
| Context | 512,000-token YaRN view, factor 1.953125 from native 262,144 |
| KV cache | 44.5 GiB, 539,789-token capacity, block size 864 |
| Prefix cache | Enabled, SHA-256 hashing |
| Speculative decoding | Quantized DFlash2 draft, K16 |
| Compilation | Eager execution; Torch compile and CUDA Graph disabled |
| Quantization | Target and draft ModelOpt NVFP4; CUTLASS target linear backend |
| Mamba state | Cache dtype `auto`; metrics reported FP32 SSM state |
| Networking / IPC | Host mode / host IPC |
| Container privileges | NVIDIA runtime, `IPC_LOCK`, non-privileged root |

vLLM warned that the 4,096 scheduled-token limit may be suboptimal with the
16-token speculative window. The wrapper also translated a 4 GiB GPU-memory
limit into `gpu_memory_utilization=0.032557`, while the deployment separately
specified the 44.5 GiB KV allocation. Metrics reflected both values; the
explicit KV capacity, rather than the percentage alone, describes the active
cache allocation.

The reported KV capacity corresponds to only 1.054 simultaneous full
512,000-token requests. Eight is therefore a scheduler maximum for short
requests, not capacity for eight maximum-context requests.

The image metadata advertises support for a 900,000-token profile, but this
deployment explicitly serves 512,000. Image capability and deployed API limit
must not be conflated.

## API and capability observations

The service exposes vLLM's OpenAI-compatible chat, completions, responses,
Anthropic messages, tokenization and metrics routes. It starts without an API
key argument: model-list requests with no authorization, an incorrect bearer
token and the configured token all returned HTTP 200. It also has no TLS on the
model process. Network access control must therefore be provided externally.

The target configuration includes a vision encoder, and the management client
advertises text and image input. The runtime enables the Qwen3 reasoning parser,
Qwen3 XML tool parser and automatic tool selection. The DFlash2 startup log
states that external multimodal embeddings are not passed to the draft model;
multimodal requests use text-only draft inputs.

Bounded smoke checks all passed:

- a synthetic 32 x 32 solid-red PNG returned `red` in 0.357 seconds;
- a strict JSON-schema request returned exactly `{"answer":42,"label":"thor"}`;
- an automatic tool-choice request produced `get_weather` with city `Beijing`;
  and
- a normal-stop Python request produced parseable code with the requested five
  assertions.

These checks confirm the serving paths, not broad visual, tool-use or code
quality.

## Single-stream measurements

The three prompts and output caps match the
[earlier local experiments](qwen3.8-27b.md#method-and-results). Each workload
had one 32-token warmup followed by three measured requests. Temperature was
zero, thinking was disabled and a fixed seed was provided. The service has no
prefix-cache reset route, so each request used a unique `cache_salt` to preserve
the exact prompt while preventing cache reuse. Decode rate is
`(completion tokens - 1) / (stream end - first content)`.

| Workload | Output cap | Decode rates | Median | Median first-content latency | DFlash accepted / proposed |
| --- | ---: | --- | ---: | ---: | ---: |
| Chinese | 256 | 17.37, 17.40, 17.37 | 17.37 tokens/s | 0.152 s | 369 / 6,384 (5.8%) |
| Short code | 256 | 62.37, 62.38, 62.34 | 62.37 tokens/s | 0.148 s | 660 / 1,776 (37.2%) |
| Long code | 1,024 | 79.48, 79.49, 79.59 | 79.49 tokens/s | 0.153 s | 2,727 / 5,568 (49.0%) |

All measured responses reached the length cap, so code throughput is not a
complete-code correctness result. Each workload's three responses had an
identical hash, unlike the non-deterministic Flash Next deployment observed in
the same test session.

The manufacturer's product-page single-stream range is 49–135 tokens/s. Both
code workloads fall inside it; the Chinese workload is below it because the
DFlash acceptance rate was only 5.8%. Prompt and generated-text predictability
materially affect speculative throughput.

## Eight-request concurrency

One warmup batch preceded three measured batches. Each batch submitted eight
simultaneous copies of the short-code workload with 128 output tokens. Unique
cache salts prevented cross-request prefix reuse. Aggregate decode counts all
delivered tokens from the first content event through final stream completion.

| Batch | Aggregate decode | Batch wall time | Per-request decode median | Per-request TTFC median |
| --- | ---: | ---: | ---: | ---: |
| 1 | 179.51 tokens/s | 5.828 s | 23.37 tokens/s | 0.387 s |
| 2 | 179.50 tokens/s | 5.823 s | 23.38 tokens/s | 0.385 s |
| 3 | 179.46 tokens/s | 5.823 s | 23.37 tokens/s | 0.384 s |

The aggregate median was 179.50 tokens/s and DFlash accepted 2,517 of 8,880
proposed tokens (28.3%). It is 1.4% below the manufacturer's displayed
182–423 tokens/s range, close enough that exact prompts, output lengths and
timing boundaries matter.

## Prefill and context capacity

One warmup and three measured requests used an exact 5,001-token chat prompt
and 32 output tokens. Unique cache salts forced all prompt tokens to be
recomputed. First-content latency was 2.612, 2.616 and 2.607 seconds, median
2.612 seconds. vLLM attributed 2.572–2.576 seconds to prefill, median about
1,941 computed tokens/s; queue time was only 8–12 microseconds.

The product page reports 2.49-second TTFT at 5K and 2,133 prefill tokens/s. The
observed median TTFT was 4.9% slower and internal prefill rate 9.0% lower.
Exact text and timing definitions may differ, so this is an observed comparison
rather than a controlled regression.

A pre-tokenized request containing 500,001 repeated ordinary tokens and one
output token succeeded. The complete HTTP request took 1,490.30 seconds; vLLM
attributed 1,490.00 seconds to prefill, or 335.57 computed tokens/s, with about
30 microseconds of queue time and no preemption. Active KV usage reached about
92.48% before returning to zero after completion.

The long-context telemetry captured the first 879 seconds of that request.
Reported GPU power averaged 69.05 W and peaked at 74.48 W; peak GPU temperature
was 69.9 C and peak system RAM use was 78.15 GB. These are sensor readings, not
whole-board input power. The repeated-token prompt validates capacity and
runtime stability, not long-context retrieval or answer quality.

A constructed request with 512,001 input and one output token was rejected
before inference with HTTP 400 in 0.077 seconds. The error explicitly stated a
maximum total context of 512,000 tokens. Thus the image's 900K profile is not
available through this deployment.

## Active-inference process snapshot

A root-level snapshot was captured while all eight concurrent requests were
running. vLLM reported zero waiting requests and zero preemptions. The Qwen
container had four processes:

| Role | Process | Threads |
| --- | --- | ---: |
| Container init and runtime entrypoint | `docker-init` | 1 |
| vLLM OpenAI API frontend | `vllm.real serve` | 62 |
| Python multiprocessing resource tracker | `multiprocessing.resource_tracker` | 1 |
| Model execution process | `VLLM::EngineCore` | 110 |

The complete host snapshot contained 485 processes and 1,212 threads. Private
artifacts retain full root-visible command lines, executable mappings, process
tree, Docker process lists, cgroups, namespaces, sockets and contemporaneous
GPU state; they remain outside the public repository because whole-host lists
contain unrelated environment-specific details.

## Operational observations

The compute-capsule root filesystem reported only about 3 GiB available and
rounded to 100% use after this deployment. The test did not consume additional
material disk space, but future image updates, cache writes and log growth have
little headroom. This should be resolved before treating the deployment as a
durable service.

At idle, the complete system used about 77.9 of 125.8 GB RAM and the Qwen
container reported about 7.0 GiB ordinary cgroup memory. During the 500K
request, system RAM remained near 78.1 GB because the large KV allocation was
already reserved at startup; increasing active KV blocks did not add tens of
GiB of new host allocation.

## Measurement status and follow-ups

This is sufficient as an initial version-pinned record of the official app,
single-stream and eight-request decode, 5K prefill, API capabilities,
near-limit capacity and active process layout. Useful follow-ups are:

1. Test long-context retrieval at multiple depths; the repeated-token capacity
   request does not measure YaRN quality.
2. Compare eager execution with a qualified CUDA Graph profile and increase
   the 4,096 scheduled-token limit in a controlled A/B test.
3. Obtain the manufacturer's exact prompts and timing definitions before
   treating the small product-page deltas as regressions.
4. Reproduce the image's 900K profile only after establishing a safe memory and
   disk budget; do not extrapolate it from the successful 500K request.

Raw requests, counters, telemetry and process inventories remain outside the
public repository.

## References

- [Earlier local Qwen3.8-27B experiments](qwen3.8-27b.md)
- [Manufacturer-published performance snapshot](../../thor.md#manufacturer-published-performance-snapshot)
