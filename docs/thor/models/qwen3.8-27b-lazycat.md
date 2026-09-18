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

### Checkpoint provenance and layout

Both image checkpoints are public, ungated Apache-2.0 Hugging Face artifacts.
The image pins exact revisions rather than mutable branch names:

- [joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt](https://huggingface.co/joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt/tree/e5ff4986938dcd0dd05ab4cce89da1b052be6ce3),
  revision `e5ff4986938dcd0dd05ab4cce89da1b052be6ce3`;
- [maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal](https://huggingface.co/maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal/tree/bd7a934213c47a9e7ef69eef36bb3325f47fd1f1),
  revision `bd7a934213c47a9e7ef69eef36bb3325f47fd1f1`.

The target's 19,743,750,248-byte main weight has Hugging Face LFS SHA-256
`5db0ff93ebdf68034770a6acec123971e618928684bd2d5f3f51346990254911`.
The 849,400,424-byte grafted MTP weight has SHA-256
`90fa0e3eed5a647c035c6df9ecabc416c0f8d573ff84ac12485b085f00a7cdf2`.
The 1,550,153,248-byte draft has SHA-256
`2228b9b22e93a88d84556419c879448ab6c490ae65c4c0b166f4962190ddbf26`.
The main target and draft hashes match both the runtime image labels and the
files extracted from that image. The official deployment therefore uses the
published artifacts byte for byte; no Lazycat-only weight delta was found.

This target is not a differently packaged copy of the resident production
checkpoint. Its source is
[JonathanColetti/Qwen3.8-27B-Uncensored](https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored),
an abliterated variant of Qwen3.8-27B. The repository quantizes 400 main
language-model linear layers as calibrated NVFP4 W4A4 with K16 blocks and FP8
scales. DeltaNet `in_proj_a`, `in_proj_b` and `conv1d`, plus the output head,
vision tower and MTP head, remain BF16. Calibration used 256 Open-Platypus
samples at up to 1,024 tokens without subsequent fine-tuning. Because the
checkpoint stores two packed 4-bit values per byte, ordinary Transformers
loading is not valid; the runtime must understand the ModelOpt FP4 layout.

The five-layer DFlash2 draft quantizes its 35 linear projections as calibrated
NVFP4 W4A4 K16. Its target-feature `fc` and dynamic convolution projections
remain BF16. Its model card reports on-policy calibration on 460 conversations
and an accepted length of 3.60/8, compared with 3.26/8 for uncalibrated
round-to-nearest NVFP4 and 3.71/8 for the BF16 source draft. Target verification
still determines which tokens are emitted; draft quantization primarily changes
draft cost, memory use and acceptance behavior.

The resident production pair has a different lineage and precision allocation:

| Checkpoint pair | Target layout | Draft layout | Weight bytes |
| --- | --- | --- | ---: |
| Resident production | Stock Qwen target; 208 attention/DeltaNet projections in FP8, 192 MLP projections in NVFP4, BF16 output head | BF16 z-lab DFlash2; local INT8 output-head optimization is applied at runtime | 27,598,150,584 |
| Lazycat | Uncensored target; 400 main projections in NVFP4 with precision-sensitive exclusions | Calibrated NVFP4 DFlash2 | 22,143,303,920 |

The Lazycat pair is about 5.08 GiB smaller. This leaves more unified memory for
KV cache, but it also means throughput and generated-token differences cannot
be attributed to the serving engine alone. The target semantic weights, target
quantization and draft quantization all changed.

The two target directories have the same chat template, vocabulary, added
tokens and semantic BPE merge table. Their tokenizer serialization is not
identical: the pad token, combining-mark pre-tokenization expression and
ByteLevel flags differ. Common benchmark text is expected to tokenize similarly,
but edge-case Unicode and batch padding remain additional variables.

The exact pair can be downloaded independently of the Lazycat image with:

```console
hf download joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt \
  --revision e5ff4986938dcd0dd05ab4cce89da1b052be6ce3 \
  --local-dir ./qwen38-lazycat-target
hf download maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal \
  --revision bd7a934213c47a9e7ef69eef36bb3325f47fd1f1 \
  --local-dir ./qwen38-lazycat-draft
```

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

## Local SGLang with the Lazycat checkpoints

After rebooting the same machine into NixOS, the target and draft embedded in
the official image were copied into the local model store. The copied
`model.safetensors` files matched the image labels exactly:

- target SHA-256
  `5db0ff93ebdf68034770a6acec123971e618928684bd2d5f3f51346990254911`;
- draft SHA-256
  `2228b9b22e93a88d84556419c879448ab6c490ae65c4c0b166f4962190ddbf26`.

The local runtime was SGLang `0.0.0.dev1+g5f55db35e`. It used native 262,144
context, four running requests, 270,336 total tokens, BF16 KV, Triton attention
and linear attention, FlashInfer CUTLASS FP4 GEMM, full decode CUDA Graph and
the existing Thor GDN verification patches. This differs materially from the
official 512K YaRN, eight-sequence, eager vLLM profile, so cross-runtime numbers
are not a checkpoint-only A/B comparison.

The resident configuration and five experimental configurations were compared,
including a complete two-target by two-draft K16 matrix and a Lazycat
target-only control. The production row used the RadixArk target, unquantized
z-lab draft and the local INT8 draft-head optimization. The same optimization
remained enabled when that draft was paired with the Lazycat target. The
Lazycat target-only row disabled speculative decoding. Every request flushed
the SGLang prefix cache; the single-stream prompts, caps, temperature, seed and
three measured repetitions were the same as the official benchmark above.

| Local SGLang configuration | Chinese | Short code | Long code | Median first-content range |
| --- | ---: | ---: | ---: | ---: |
| Resident production, DFlash K16 | 19.62 tok/s | 72.99 tok/s | 75.09 tok/s | 0.153–0.154 s |
| RadixArk target + Lazycat NVFP4 draft, K16 | 19.86 tok/s | 73.48 tok/s | 73.08 tok/s | 0.186–0.189 s |
| Lazycat target only | 15.31 tok/s | 15.32 tok/s | 15.28 tok/s | 0.168–0.175 s |
| Lazycat target + z-lab BF16 draft/INT8 head, K16 | 21.77 tok/s | 61.75 tok/s | 78.66 tok/s | 0.200–0.203 s |
| Lazycat target + draft, K16 | 21.87 tok/s | 70.26 tok/s | 89.95 tok/s | 0.166–0.168 s |
| Lazycat target + draft, K8 | 23.14 tok/s | 52.63 tok/s | 66.16 tok/s | 0.161–0.164 s |

On the RadixArk target, replacing the BF16/INT8-head draft with the Lazycat
NVFP4 draft changed the three rates by +1.2%, +0.7% and -2.7%. It saved about
2.14 GiB of draft weights but did not reproduce the Lazycat target's long-code
gain. On the Lazycat target, its native NVFP4 draft was 0.5%, 13.8% and 14.4%
faster than the BF16/INT8-head draft. The latter logged accepted lengths near
2.3, 6.2 and 10.2 for the three workloads, while the NVFP4 draft logged about
2.0, 6.7 and 10.1. Similar long-code acceptance with lower throughput indicates
that BF16 draft computation cost, not just acceptance, matters on this runtime.

All four target/draft pairings produced different output hashes, though every
configuration was stable across its own three runs and reached the same output
cap. The matrix therefore separates checkpoint pairings, but it is not a
fixed-generated-token kernel benchmark: changed output trajectories also change
DFlash predictability. It nonetheless shows that neither draft substitution
alone explains the full result. Target lineage/quantization and its interaction
with the draft both matter.

Against resident production, Lazycat K16 was 11.5% faster on Chinese and 19.8%
faster on long code, but 3.7% slower on short code. K8 was 17.9% faster on the
low-acceptance Chinese workload, but 27.9% slower on short code and 11.9%
slower on long code. K16 is therefore the stronger general candidate; K8 only
won when K16 spent most of its verify window on rejected tokens.

The draft checkpoint declares `block_size=8`. SGLang used that without warning
for K8, while K16 deliberately overrode it and logged a mismatch. K16 matches
the official vLLM deployment and was valid in SGLang, but the distinction must
be explicit. K16 logged acceptance length/rate near 2.0/7–8% for Chinese,
6.65/38% for short code and up to 10.07/60% for long code. K8 logged about
2.2/17%, 4.88/55% and up to 6.35/76%, respectively. Acceptance-rate
percentages have different denominators across the two windows and should not
be compared without the accepted length.

Four-request and 5K-prompt measurements further favored Lazycat K16:

| Case | Resident production | Lazycat K16 | Difference |
| --- | ---: | ---: | ---: |
| Four-request aggregate decode | 135.03 tok/s | 172.50 tok/s | +27.8% |
| Four-request end-to-end output | 126.15 tok/s | 157.76 tok/s | +25.1% |
| Four-request median per-request decode | 38.52 tok/s | 56.54 tok/s | +46.8% |
| Exact 5,001-token prompt TTFC | 1.804 s | 1.689 s | 6.4% lower |

The local K16 short-prompt results were also faster than the official vLLM
profile on this test set: 21.87 versus 17.37 tokens/s for Chinese, 70.26 versus
62.37 for short code, 89.95 versus 79.49 for long code, and 1.689 versus 2.612
seconds at 5K. The different context, scheduler, KV and graph settings prevent
attributing these deltas to SGLang alone.

Both resident production and Lazycat K16 correctly emitted an automatic
`get_weather` call with JSON arguments `{"city":"上海"}`. Within each tested
configuration, all three measured outputs had identical hashes. However, the
target-only, K8 and K16 outputs differed from one another despite temperature
zero and a fixed seed. Their visible content remained reasonable, but the
speculative paths are not byte-for-byte equivalent to target-only generation.
This needs correctness and quality qualification before replacing production.

### Local long-context qualification

The Lazycat K16 pair subsequently passed bounded 32K, 64K and 128K retrieval
checks under the same local SGLang configuration. Each synthetic archive placed
the exact values `cobalt-7319`, `willow-4826` and `silver-9053` near 5%, 50% and
95% of its filler. Prompt sizes were calibrated through the running server's
`/tokenize` route, not inferred solely from the offline tokenizer. Every case
flushed the prefix cache first.

Two independent cold requests ran at each length. The schema request disabled
tool choice and required an object with exactly the three string fields. The
tool request exposed `record_vault` and required exactly one automatic call
with those fields as arguments. Qwen places tool definitions before the user
archive, so the two prompt types have different leading tokens and cannot reuse
one another's radix-cache prefix.

| Path | Input tokens | First content | Complete | Output tokens | Finish | Retrieval |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| Strict JSON schema | 32,767 | 30.906 s | 32.077 s | 36 | `stop` | 3/3 |
| Automatic tool call | 32,767 | 31.337 s | 32.753 s | 69 | `tool_calls` | 3/3 |
| Strict JSON schema | 65,535 | 107.390 s | 109.264 s | 45 | `stop` | 3/3 |
| Automatic tool call | 65,537 | 108.475 s | 111.115 s | 69 | `tool_calls` | 3/3 |
| Strict JSON schema | 131,072 | 396.082 s | 401.321 s | 36 | `stop` | 3/3 |
| Automatic tool call | 131,073 | 397.953 s | 402.557 s | 69 | `tool_calls` | 3/3 |

All schema responses parsed to the exact required object. All tool cases emitted
one `record_vault` call whose parsed arguments exactly matched it. The 128K
schema TTFC is within 0.3% of the resident checkpoint's earlier 397.149-second
cold archive result, although the prompts and structured-output constraint are
not identical. The checkpoint change therefore did not materially improve the
dominant 128K cold-prefill cost. TTFC also grew much faster than input length:
about 31, 107 and 396 seconds as context doubled, making long-prefill work a
more important optimization target than short decode for this workload.

The service-reported prompt lengths also explain an apparent tool-path cost.
The 32K pair had identical input length, while the tool cases added only two
tokens at 64K and one at 128K. With the tested 1024-token prefill chunk those
small additions cross an exact chunk boundary: 65,535 versus 65,537 requires
64 versus 65 chunks, and 131,072 versus 131,073 requires 128 versus 129. The
observed tool/JSON TTFC gaps therefore cannot be attributed to the parser or
grammar engine; the extra short tail chunk is a direct confounder.

After another cache flush, a cold 128K schema request was disconnected after
15.011 seconds, before first output. Five seconds later a short request returned
`THOR_CANCEL_OK` in 0.665 seconds. Logs showed the long prefill cease with about
108K tokens still pending before the short 18-token prefill ran, confirming that
the patched disconnect path released the execution slot.

An experiment-side monitor sampled host memory once per second and applied the
production guard thresholds throughout the trial. Across 1,440 samples, minimum
`MemAvailable` was 61.13 GiB, minimum `MemFree` was 15.20 GiB and minimum free
swap was 30.71 GiB. No threshold fired. This establishes comfortable headroom
for these single-request 128K cases, not arbitrary concurrent long prompts.
The normal production SGLang service, memory monitor and health timer were
restored afterward with HTTP health 200 and no memory-stop lock.

These checks qualify synthetic deep retrieval, schema enforcement, tool
argument construction and client cancellation through 128K. They do not
measure broad long-context reasoning, repository-scale coding quality or
multiple simultaneous cold prefills.

### Chunked-prefill screening

A follow-up single-variable screen kept the Lazycat K16 pair, Triton
attention backends, BF16 caches, disabled prefill graphs and the exact 65,535
token schema fixture unchanged. Candidate runs first completed a 16K warm-up,
then flushed the radix cache before the measured request. The earlier 1024
result used the same fixture hash but came from the preceding long-context
qualification rather than this screening harness.

| Chunk size | Cold 64K first content | Complete | Repeats | Retrieval |
| ---: | ---: | ---: | ---: | --- |
| 1024 | 107.390 s | 109.264 s | 1 earlier baseline | 3/3 |
| 2048 | 104.139, 104.194 s | 106.016, 106.071 s | 2 | 3/3 |
| 4096 | 104.214 s | 107.223 s | 1 | 3/3 |
| 8192 | 105.628 s | 108.259 s | 1 | 3/3 |

The 2048 repeats differed by only 0.055 seconds and improved first-content
latency by about 3.0% relative to 1024. Increasing the chunk to 4096 produced
no further first-content gain, while 8192 regressed toward the baseline. This
shows only a modest gain from the values screened in this implementation; it
does not establish that chunk size can affect only a constant or linear term.
Exact causal attention preserves the same total token-pair count for every
chunk size, but kernel efficiency or repeated prefix preparation can still
change the measured quadratic coefficient.

Regression over complete chunks from the measured runs reinforces that
distinction. The fitted per-chunk slope against prior-prefix length was
76.6 microseconds per prefix token at chunk 2048, 145.2 at 4096 and 255.9 at
8192. Dividing each slope by its chunk size gives similar values, while total
complete-chunk time stayed near 106.0, 106.1 and 107.5 seconds. The current
screen therefore found no evidence that a larger service chunk removes the
dominant prefix-dependent work. The later 128K and mixed-load tests below favor
keeping 1024 when interactive decode latency matters.

The same startups exposed two useful implementation facts. Each target load
logged exactly 48 successful SiLU+mul+FP4-quant fusions, matching the 48 Gated
DeltaNet layers; source inspection showed that the 16 full-attention dense
MLPs do not call the same fusion initializer. FlashInfer FP4 autotuning was
already enabled on SM110 and loaded architecture- and environment-specific
caches for both target and draft. Further tactic work must therefore establish
missing real serving shapes rather than assume that the deployment is using a
single untuned CUTLASS tactic.

### Kernel-level prefill attribution

An Nsight Systems 2026.4.1 trace isolated one correct 65,535-token schema
request at chunk size 1024. It returned all three facts, reached first content
in 108.220 seconds and completed in 110.099 seconds. The unprofiled baseline was
107.390 seconds, so profiling added about 0.8% to TTFC.

The trace contained exactly 1,024 Triton `_fwd_kernel` launches: 64 chunks
times the model's 16 full-attention layers. They consumed 89.243 seconds, or
82.5% of observed TTFC and 84.1% of the summed GPU-kernel time. Regressing the
attention time accumulated per chunk against chunk index gave
`-11.444 + 44.631 * index` milliseconds with R-squared 0.99947. The matching
whole-chunk GPU window grew by 44.920 milliseconds per index with R-squared
0.99937. Full attention therefore explained 99.4% of the measured
prefix-dependent slope.

The other GPU buckets remained approximately flat per chunk: FP4 GEMM about
100.8 milliseconds, GDN about 65.7 milliseconds, FP4 quantization about 24.3
milliseconds, normalization/RoPE/activation about 36.1 milliseconds and BF16
GEMM about 16.9 milliseconds. GPU clocks stayed at 1,385--1,386 MHz, EMC at
4,266 MHz and temperature at 53.6--64.3 degrees Celsius. Minimum
`MemAvailable` was 55.14 GiB and the experiment memory guard did not fire.
This rules out sustained thermal downclocking and assigns essentially all of
the observed super-linear growth to the full-attention prefill kernels rather
than GDN, GEMM, draft materialization or host scheduling.

A process snapshot during the request contained the expected Nsight wrapper,
tokenizer, scheduler, detokenizer, compile worker and benchmark client. The raw
trace, telemetry and root-visible process snapshots remain private because
they contain host details.

### FlashInfer prefill correctness screen

A minimal backport of SGLang PR #39811 changed only the SM110 backend gate.
The experiment retained Triton for target decode, draft attention and all GDN
phases, and selected FlashInfer only for target full-attention prefill. The
server started successfully with installed FlashInfer 0.6.17 and logged the
intended resolved backends.

The first 16,386-token correctness request reached content in 6.932 seconds
and completed in 8.422 seconds, but retrieved none of the three sentinel
values: it returned unrelated prompt fragments instead. The harness therefore
stopped before the planned 64K timing. There was no server crash, OOM, Xid or
thermal event. This path is much faster but unusable on the installed stack;
it also validates PR #39811's warning that its Thor measurements did not
establish accuracy parity. FlashInfer 0.6.18 was used by that PR and remains a
separate dependency-upgrade experiment, not an assumed correctness fix. No
production source or dependency was changed.

### FA4 source qualification

The image contains both `flash-attn-4` 4.0.0b19 under site-packages and an
SGLang-vendored FA4 tree. Both copies still contain the head-dimension-256
forward assertion rejecting `seqused_q/seqused_k`. Neither contains #2810's
rounded paged-KV extent nor #2880's `domain_offset_aligned` and singleton-stride
alignment changes. The installed FA4 path therefore failed the source gate and
was not run against the service. Both source copies must be updated together
before the operator-level correctness test described below.

### SM110 Triton tuning

The pinned Triton extend-attention configuration uses `BLOCK_M=64`,
`BLOCK_N=64`, eight warps and one pipeline stage for this SM110,
QK/V-head-dimension-256 shape. A source-mounted experiment changed only this
shape, leaving the Lazycat K16 pair, 1024-token service chunk, BF16 cache and
all other backends unchanged.

| Extend-attention configuration | Cold 64K first content | Complete | Result |
| --- | ---: | ---: | --- |
| Pinned `64x64`, stages 1 | 107.390 s | 109.264 s | 3/3 |
| `128x64`, stages 1 | 75.099, 75.101 s | 77.354, 77.356 s | 3/3 both |
| `128x128`, stages 1 | 75.034 s | 77.290 s | 3/3 |
| `128x64`, stages 2 | 69.225, 69.562 s | 71.297, 71.630 s | 3/3 both |
| `128x64`, stages 3 | not run | not run | compile rejected |

Doubling `BLOCK_M` halves the number of query programs that independently
stream the prefix KV for each Q head and reduced 64K TTFC by about 30%.
Doubling `BLOCK_N` produced no further material change. A second pipeline stage
reduced the two-run mean to 69.393 seconds, 35.4% below the pinned baseline.
Three stages required 262,688 bytes of shared memory versus Thor's 232,448-byte
limit and were rejected before a measured request. The two stages=2 repeats
differed by 0.337 seconds and produced identical parsed values and output hash.

The gain increased at 128K:

| Path | Pinned TTFC | Tuned TTFC | Tuned complete | Retrieval |
| --- | ---: | ---: | ---: | --- |
| Strict JSON schema, 131,072 tokens | 396.082 s | 242.556 s | 247.660 s | 3/3 |
| Automatic tool call, 131,073 tokens | 397.953 s | 246.278 s | 251.428 s | 3/3 |

That is a 38.8% schema-TTFC reduction and 38.1% tool-TTFC reduction. The tuned
128K schema run kept GPU clocks at 1,385--1,386 MHz, reached at most 65.7
degrees Celsius, retained at least 61.09 GiB `MemAvailable` and did not trigger
the memory guard. A 15-second client disconnect still released the long
request; after the five-second observation delay, a short request returned
`THOR_CANCEL_OK` in 0.663 seconds.

The first mixed-load test also exposed scheduler behavior that isolated TTFC
does not show. Two `ignore_eos` decode requests, each forced to 1,024 output
tokens, were started before the same cold 64K prefill:

| Kernel / scheduler | 64K TTFC | Decode p95 gap | Decode maximum gap | Decode completion |
| --- | ---: | ---: | ---: | ---: |
| Pinned, interval 0 | 108.716 s | 107.963 s | 107.963 s | 148.992 s |
| Tuned, interval 0 | 70.323 s | 69.706 s | 69.706 s | 111.005 s |
| Tuned, interval 1 | 77.274 s | 1.937 s | 2.449 s | 111.262 s |

With the default `prefill_decode_interval=0`, both decode streams received only
six payload events during the prefill and each had one near-TTFC-size gap. The
kernel improvement shortened but did not solve that starvation. Setting the
existing scheduler option to 1 runs one decode round after each prefill batch:
the two streams then received 65--66 events during prefill, with median gaps
of 1.25--1.27 seconds. It added 9.9% to mixed-load prefill TTFC but left the
decode requests' total completion time effectively unchanged. For an
interactive service this is the qualified scheduling candidate; interval 0 is
appropriate only when isolated-prefill latency is deliberately prioritized.
No tuned kernel or scheduler option was installed into the managed service.

### Independent review provenance

This investigation used several model-assisted passes whose roles are recorded
so that their suggestions are not mistaken for measurements:

- **GPT-6-Astra Medium** performed the earlier deployment inspection,
  benchmark construction and initial analysis recorded in this document.
- **GPT-5.6-Sol xhigh** performed the current local/source verification,
  profiling, controlled backend/tile experiments and synthesis with the
  measured results.
- **Claude Opus Max** supplied an independent source-level critique through an
  operator-provided transcript. It reviewed the pinned SGLang, FlashInfer and
  Triton code and challenged the initial optimization ordering.
- **GPT-6-Pro WebChat** supplied a second independent review through the
  [shared response](https://chatgpt.com/s/t_6aacfb01d0cc8191b647e1c2ee48a113).
  The final answer and its embedded research report were both inspected.

Model reviews are leads, not benchmark evidence. Claims below are either tied
to the local measurements above, verified against the pinned source/runtime,
or explicitly retained as experiments. The two external reviews independently
agreed that a three-point, three-parameter quadratic fit is interpolation rather
than proof: it strongly motivates investigating full attention, but cannot by
itself assign the fitted quadratic percentage to attention kernels.

The target config has 16 full-attention and 48 Gated DeltaNet layers. Full
attention is the model's intrinsic quadratic GPU operation; GDN, MLP and normal
incremental draft materialization are linear in new tokens. The isolated trace
now measures full attention as the dominant cost and source of virtually all
prefix-dependent growth. It does not by itself distinguish inefficient kernel
tiling, redundant KV traffic or another device-level cause inside that kernel.

### Revised optimization research targets

The combined evidence changes the order of work:

1. The cold 64K timeline has assigned 82.5% of TTFC and 99.4% of its
   prefix-dependent slope to full attention while excluding thermal decline.
   A lighter 128K trace is optional confirmation rather than a prerequisite for
   backend work.
2. Change only the target prefill backend. As of
   2026-09-18, open [SGLang PR #39811](https://github.com/sgl-project/sglang/pull/39811)
   at `5705691f4c3cdcc669cca04c7d19e14da8d607b9` admits FlashInfer full
   attention for hybrid-GDN models on SM110. Its Thor evidence uses FlashInfer
   0.6.18 and reports shared-prefix output throughput, not cold-prefill TTFC;
   accuracy parity was not established. The isolated 0.6.17 backport resolved
   the requested phase split and was fast at 16K, but failed retrieval before
   the 64K benchmark. Reject it for service use. Any 0.6.18 retest must remain
   behind the same correctness gate. FlashInfer 0.6.17's separate CUTLASS FMHA
   prefill dispatcher does not accept this model's `(256,256)` QK/V head
   dimensions.
3. The installed FA4 trees lack the required fixes and are ineligible for a
   service test. After updating both copies, require an operator-level BF16,
   GQA 24:4, head-dimension-256, paged-KV and unequal-Q/K correctness check.
   Upstream
   [FlashAttention #2810](https://github.com/Dao-AILab/flash-attention/pull/2810)
   and [#2880](https://github.com/Dao-AILab/flash-attention/pull/2880), merged
   2026-09-11, remove relevant `seqused_q/k`, paged-KV and output-alignment
   obstacles. Their published performance validation is on SM103, not Thor.
4. The Triton sweep found `128x64`, eight warps and two stages as the current
   reliable candidate. It passed repeated 64K retrieval plus 128K schema, tool
   and cancellation gates and reduced 128K TTFC by about 39%. Before managed
   deployment, package the exact SM110/D=256 conditional as a reviewable
   runtime patch and run broader output/logit parity plus representative agent
   workloads. Do not generalize the tile to other architectures or head dims.
5. Keep the full-attention MLP SiLU+NVFP4 fusion and packed KV-only DFlash
   projection as secondary linear/decode experiments. The former can save MLP
   intermediates but not attention pairs; the latter normally affects only
   newly materialized draft rows. If profiling instead finds repeated processing
   of the entire prefix, remove that repetition before merely reducing its
   projection width. FlashInfer cuDNN FP4 GEMM is also an experimental linear
   path: the installed backend accepts SM110, while SGLang `auto` currently
   resolves to FlashInfer CUTLASS on this device.
6. Keep the service chunk at 1024 while concurrency matters. The earlier 2048
   screen saved about 3% in isolation, but default scheduling starved existing
   decodes for the entire long prefill. Use `prefill_decode_interval=1` for an
   interactive deployment; it bounded the observed mixed-load gap below 2.45
   seconds. Preserve retrieval, schema, tool, mixed-decode and cancellation
   checks as correctness gates.
7. Independently determine whether an uncensored-target on-policy K16 draft
   calibration improves acceptance without losing the quantized draft's memory
   and compute advantage. This remains a quality/decode investigation rather
   than a remedy for the 396-second prefill.

FlashInfer PR
[#5302](https://github.com/flashinfer-ai/flashinfer/pull/5302) is explicitly
excluded from this long-prefill track: it is an experimental prepared SM110 GQA
decode path, not a causal prefill implementation for `q_len=1024–8192` and
head dimension 256.

SGLang loaded the quantized draft directly in 1.7–1.9 seconds. It disabled its
fused DFlash KV-materialization path because that path does not support the
draft's ModelOpt FP4 QKV projection; the unfused fallback still produced the
measurements above. A process snapshot taken during K16 inference contained
405 host processes. The container included the API process, multiprocessing
resource tracker, scheduler, detokenizer, Torch Inductor compile pool and the
benchmark client. Complete root-visible process and cgroup snapshots remain in
private raw evidence because they include unrelated host details.

One dual-boot operational hazard was confirmed: the official container shares
the NixOS Docker store and had `unless-stopped` restart policy, so it started
automatically alongside the managed SGLang service after reboot. It was stopped
before testing to avoid unified-memory contention. Experiments used bounded
systemd units with independent cleanup. Earlier batches verified recovery to
the normal managed SGLang service with HTTP health 200. At operator request,
the later tuning batch instead left the managed service, memory watcher and
health timer inactive. The official container and all experiment containers
were stopped, and no memory-stop lock was present.

These results justify retaining Lazycat K16 as a replacement candidate, not
switching it into production yet. It has now passed bounded fixed-context
retrieval, tool/structured-output, memory-headroom and cancellation checks
through 128K. The remaining replacement gate is broader quality evaluation on
representative coding and agent workloads, especially because target lineage
and speculative paths changed the deterministic output trajectories.

### Experiment handoff TODO

The next session should resume from the tuned Triton candidate, in this order:

1. Run direct operator-level numerical parity between the pinned and tuned
   kernels at prefix lengths 0, 32K, 64K and 128K using BF16, GQA 24:4,
   head dimension 256 and a 1024-token query chunk. Record exact equality,
   maximum absolute/relative error and NaN/Inf counts; use a sampled independent
   reference where a full 128K reference would consume excessive memory.
2. If parity passes, package only the measured SM110 and `Lq=Lv=256` change:
   `BLOCK_M=128`, `BLOCK_N=64`, eight warps and two stages on the regular
   `_fwd_kernel` path. Do not change the unified kernel or generalize it to
   other architectures/shapes. Keep an explicit source-level rollback.
3. Build the service candidate with the existing 1024-token chunk and
   `prefill_decode_interval=1`. Re-run 1/2/3 concurrent decode streams during
   128K prefill, strict-schema and tool calls, disconnect cancellation, short
   latency, representative coding/agent workloads and a multi-hour stability
   run. Only then enable the managed service and verify recovery after reboot.
4. Keep FlashInfer 0.6.18 and updated FA4 as separate backend experiments.
   MLP fusion, KV-only draft projection and draft calibration remain lower
   priority until the Triton candidate is qualified.

Current stop state on 2026-09-18: the managed inference service, memory watcher
and health timer are inactive; the official and experimental containers are
stopped. This is intentional at the operator's request and is not a failed
health state.

The completed qualification used this staged order:

1. At each context length, place three exact-value facts near 5%, 50% and 95%
   of a synthetic archive, flush the prefix cache and require all three values
   in a strict JSON-schema response. Record exact input/output tokens,
   first-content latency, completion time, finish reason and sampled memory.
2. Independently construct a service-counted prompt at each length and require
   one automatic tool call whose arguments contain the three retrieved values.
   The Qwen template places tool definitions ahead of the archive, so the
   schema and tool prompts do not share a reusable leading prefix; flush both
   and report their cold latencies separately rather than claiming cache reuse.
3. Abort a cold 128K streaming request before first output, then require a short
   request to complete promptly. Confirm that the scheduler slot and temporary
   request state were released.
4. Preserve the existing host-memory thresholds throughout the trial and verify
   the requested final service state afterward. A passing bounded run establishes
   headroom for these cases, not safety for arbitrary concurrent long prompts.

## References

- [Earlier local Qwen3.8-27B experiments](qwen3.8-27b.md)
- [Manufacturer-published performance snapshot](../../thor.md#manufacturer-published-performance-snapshot)
