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

## References

- [NVIDIA r39.2 variable types and display enum values](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Include/NVIDIAConfiguration.h)
- [NVIDIA r39.2 UEFI form definitions and variable attributes](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.vfr)
- [NVIDIA r39.2 additional configuration constants](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.h)
- [NVIDIA r39.2 menu help text](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.uni)
- [Original SGLang deployment reference for DGX Spark](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) — adapted and measured on Thor; its Spark CPU affinity and attention settings are not directly transferable.
- [Author's DFlash2 single-stream 125–133 TPS report](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — external result, not a local measurement.
- [Huihui NVFP4 checkpoint and model card at the tested revision](https://huggingface.co/Vtuber-plan/Huihui-Qwen3.8-27B-abliterated-NVFP4/tree/43aa7ff5eef05ab50a3bfa6aca581085312c7a04)
