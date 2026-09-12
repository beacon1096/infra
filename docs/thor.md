# Jetson AGX Thor: hardware and inference notes

## Snapshot

Read-only inspection on 2026-09-11, after the initial NixOS installation and
display handoff fix. Firmware reports `39.2.0-gcid-45755727`; the installed
JetPack NixOS configuration uses L4T 39.2.1 and Linux 6.8.12.

Linux exposed 71 variables under `/sys/firmware/efi/efivars`, including 20 in the
NVIDIA public-variable namespace. Payloads were read for 16 NVIDIA settings or
status variables and five standard UEFI variables. This is an observed snapshot,
not a declaration that every setting below is required by NixOS.

The raw inventory is not committed: it includes device-specific metadata.
Addresses, device identifiers, EFI device paths, certificates, authentication
data and opaque payloads are omitted here.

## NVIDIA variables

GUID: `781e084c-a330-417c-b678-38e696380cb9`.

Hex payloads below exclude the four-byte efivarfs attribute header. Multibyte
integers are little-endian. Attribute `0x07` means nonvolatile, boot-service and
runtime access; `0x06` means boot-service and runtime access without nonvolatile
storage.

| Variable | Attributes | Payload | Interpretation |
| --- | --- | --- | --- |
| `SocDisplayHandoffMode` | `0x07` | `00` | Never: reset the display on UEFI exit |
| `SocDisplayHandoffMethod` | `0x07` | `01` | simplefb |
| `BoardRecoveryBoot` | `0x07` | `00` | Recovery boot not requested |
| `DgpuDtEfifbSupport` | `0x07` | `00` | dGPU EFIFB support in Device Tree mode disabled |
| `NewDeviceHierarchy` | `0x07` | `01` | Add new boot options at the top of the boot order |
| `L4TDefaultBootMode` | `0x07` | `01 00 00 00` | Direct; this is the L4T launcher setting, not the currently selected EFI loader |
| `IpmiNetworkBootMode` | `0x07` | `00` | IPv4 for IPMI-requested network boot; does not itself enable network boot |
| `MemoryTestControl` | `0x07` | 32 zero bytes | Test level Ignore, with all remaining fields zero |
| `RootfsStatusSlotA` | `0x07` | `00 00 00 00` | NVIDIA status: normal |
| `RootfsStatusSlotB` | `0x07` | `00 00 00 00` | NVIDIA status: normal |
| `RootfsRetryCountMax` | `0x06` | `03 00 00 00` | Retry count 3 |
| `RootfsRedundancyLevel` | `0x06` | `00 00 00 00` | Recorded value 0; no NixOS root-filesystem redundancy is implied |
| `BootChainFwCurrent` | `0x06` | `00 00 00 00` | Current firmware boot-chain value 0 |
| `ServerPowerControlSetting` | `0x07` | `00` | Enum selects 50 ms input-power-capping window; applicability to this board was not verified |
| `ExposeRtRtcService` | `0x07` | `00` | Recorded value 0; behavior not independently verified |
| `SystemFwVersions` | `0x06` | `00 02 27 00 00 02 27 00` | Raw version data retained without an assumed structure |

The other four NVIDIA variables were enumerated but their payloads were not
read: `TegraPlatformSpec`, `TegraPlatformCompatSpec`, `ProfilerBase` and
`ProfilerSize`.

NVIDIA rootfs status variables are firmware bookkeeping; they do not establish
the presence of an A/B NixOS installation. This host uses one ext4 root partition.

## Standard UEFI variables

GUID: `8be4df61-93ca-11d2-aa0d-00e098032b8c`.

| Variable | Attributes | Value | Interpretation |
| --- | --- | --- | --- |
| `SecureBoot` | `0x06` | `00` | Secure Boot disabled |
| `SetupMode` | `0x06` | `01` | Setup Mode active |
| `BootCurrent` | `0x06` | `09 00` | `Boot0009`: Linux Boot Manager, using systemd-boot |
| `BootOrder` | `0x07` | `0009,0008,0007,0004,0003,0002,0001,0000,0005,0006` | Observed order; identifiers are local to this firmware installation |
| `Timeout` | `0x07` | `05 00` | Firmware boot-menu timeout: 5 seconds |

## Display handoff and visibility limits

The working configuration uses Device Tree mode. Before the fix,
`SocDisplayHandoffMode` was `01` (Always), which means **never reset**, not
always reset. Changing it to `00` (Never) allowed the NVIDIA DRM driver to
provide a 2560×1440 framebuffer and a visible login prompt. The method remained
`01` (simplefb). These are firmware settings; the NixOS host module does not
automatically write these variables.

No separately named ACPI/Device Tree selection variable appeared in the Linux
inventory. Device Tree boot was confirmed from the running system instead.

Not all UEFI menu settings are visible after boot. The r39.2 form definitions
declare settings such as `QuickBootEnabled`, `EnablePcieInOS`, `SerialPortConfig`,
`KernelCommandLine`, `AcpiTimerEnabled`, `UefiShellEnabled`,
`EnabledPcieNicTopology` and `LockAllVarsConfig` without runtime access. Their
absence from Linux does not mean they are disabled. Inspecting these requires
the UEFI setup interface or a suitable pre-boot tool.

## Qwen3.8-27B inference retest (2026-09-12)

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

### Method and results

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

### Retained experimental configuration

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

## Huihui NVFP4 trial (2026-09-12)

The abliterated checkpoint
`Vtuber-plan/Huihui-Qwen3.8-27B-abliterated-NVFP4` was tested at revision
`43aa7ff5eef05ab50a3bfa6aca581085312c7a04`. Both ordinary decoding and DFlash2
loaded successfully on Thor, using the same pinned image, draft, and common
server settings as above. The target adds `--quantization modelopt` and
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

### Capability smoke checks and retained state

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

### Next experiments, in priority order

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

## Flash Next and DeepSeek-v4 Flash candidates

Source review used the Qwen Flash Next deployment at
`d03809008834124e80223c3482f2ddb59577a48f` and the DeepSeek deployment at
`fdcd538fbf95fb15b2d6850db9613d22b2c889b8`. Their published results are Spark
measurements, not Thor measurements.

Qwen3.8 Flash Next is the more practical next candidate while retaining a
desktop. Its approximately 99 GiB checkpoint includes a 26.82 GiB PLE table,
leaving approximately 72 GiB of GPU-resident weights. The additional packed PLE
file is a disk copy mapped by a CPU worker, not an additional 27 GiB that must
always be resident. The deployment reserves 26 GiB of host memory by default;
PLE page cache, desktop processes and driver allocations share that reserve.
Full advertised context and concurrency have not been validated on Thor.

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

CUDA graphs, FP8 KV and MTP remain separate full-model follow-up experiments.
The initial API is an experimental loopback-only container, not a persistent
fleet inference service.

Probe scripts and detailed results remain outside the public repository.

The DeepSeek single-Spark recipe has two additional constraints. It uses a
REAP-K216 expert-pruned model with EXL3/Trellis quantization, rather than merely
quantizing the complete original model. Its default launch requires about
114.3 GiB of free memory, leaving little room for a desktop on this device.
The build also explicitly targets SM120/SM121-family kernels, including
`CUTE_DSL_ARCH=sm_121a`; changing a Torch architecture flag alone is not evidence
that its sparse attention and quantized expert kernels support Thor's SM110.
It is therefore a porting project before it is a model-download experiment.

Benchmark comparisons must retain their context: the Flash Next repository
reports approximately 48.7 tokens/s for one stream and 162.9 aggregate for eight
streams, whereas the author's separate adaptation report gives different
workloads/settings. That report's approximately 70 tokens/s DeepSeek result
uses two machines. Neither figure is a directly comparable single-Thor result.

## References

- [NVIDIA r39.2 variable types and display enum values](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Include/NVIDIAConfiguration.h)
- [NVIDIA r39.2 UEFI form definitions and variable attributes](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.vfr)
- [NVIDIA r39.2 additional configuration constants](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.h)
- [NVIDIA r39.2 menu help text](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.uni)
- [Original SGLang deployment reference for DGX Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — adapted and measured on Thor; its Spark CPU affinity and attention settings are not directly transferable.
- [Author's DFlash2 single-stream 125–133 TPS report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
- [Huihui NVFP4 checkpoint and model card at the tested revision](https://huggingface.co/Vtuber-plan/Huihui-Qwen3.8-27B-abliterated-NVFP4/tree/43aa7ff5eef05ab50a3bfa6aca581085312c7a04)
- [Qwen3.8 Flash Next Spark deployment at the reviewed revision](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark/tree/d03809008834124e80223c3482f2ddb59577a48f)
- [DeepSeek-v4 Flash single-Spark deployment at the reviewed revision](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark/tree/fdcd538fbf95fb15b2d6850db9613d22b2c889b8)
- [DeepSeek Spark checkpoint and disk requirements](https://huggingface.co/0xSero/deepseek-v4-flash-0731-spark)
- [DeepSeek Spark runtime Dockerfile and architecture targets](https://github.com/0xSero/deepseek-v4-flash-0731-spark-sparkinfer/blob/main/Dockerfile)
