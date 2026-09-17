# MiniMax H3: Lazycat deployment and benchmark

[Thor overview](../../thor.md)

Inspection and trial: 2026-09-18. This is a read-only record of the official
Lazycat package installed on one Thor T5000, not a benchmark of upstream
MiniMax H3 under its recommended serving stacks.

Tested platform versions:

- AI Pod: `2.2.4-nightly.20260917081204+43444c8`
- Lazycat compute-capsule firmware (`算力舱固件`):
  `2.2.4-nightly.20260917081206+43444c8`
- Lazycat MiniMax H3 app/LPK: `0.1.9`
- MiniMax H3 compute runtime: `runtime-160-0.1.1`

The observed host ran Ubuntu 24.04.4, Jetson Linux R39.2, Linux
6.8.12-1021-tegra, NVIDIA driver 595.78 and CUDA 13.2 in the 120 W power mode.
The compute-capsule control panel set the fan profile to Performance
(`风扇-性能模式`). Private addresses, the device hostname and identifiers are
omitted.

## Lazycat management app

A read-only inspection of the original package and its persistent deployment
record on the Lazycat microserver found:

- package ID `cloud.lazycat.aipod.minimax-h3`, package version `0.1.9`;
- management image
  `registry.lazycat.cloud/catdogai/minimax-h3-lpk:0.1.9-amd64-v1`, digest
  `sha256:8a536b135d4aa163d039c2a500adf0adcd800310a90ca54336462af5cf142137`;
- original LPK SHA-256
  `2ab34fa7be421c80781855f28d25aab97bc1e68ca3dc9b28b50716d9f6ecc479`;
- stored model ID `minimax-h3-video`, model version `0.1.9` and deployment
  mode `custom`; and
- one requested and maximum concurrent sequence, a stored context-length
  value of 8, and an estimated 72 GiB of device memory.

The stored deployment record pins the compute image to
`registry.lazycat.cloud/catdogai/minimax-h3:runtime-160-0.1.1` and records the
warm-cache artifact `minimax-h3-t5000-warm-cache.tar.gz`. The management app
reported 291.03 seconds from starting its environment checks through a healthy
model API; this wider interval is distinct from the runtime startup timings
below.

The MiniMax H3 app's deployment page exposed no selectable deployment options.
Consequently, the stored concurrency, context-length and memory fields above
describe the app's fixed/default deployment rather than choices made for this
test.

No separate compute-capsule configuration schema or release version was
present in the package manifest or deployment record. The reproducible version
identity is therefore the platform/firmware build, app version `0.1.9`, runtime
tag and image digest rather than a single combined H3 version.

## Packaged runtime

The package is not the upstream MiniMax vLLM or SGLang server. The Lazycat
agent starts one Docker Compose service using:

- image `registry.lazycat.cloud/catdogai/minimax-h3:runtime-160-0.1.1`;
- image digest
  `sha256:e37d78b4fdda01fa3e7cf82a6cd8dc7b14f4249bbfb12fa7eebe66db22b53ad4`;
- image creation time 2026-09-11 and local image size reported as 85.38 GB;
- host networking and IPC, all NVIDIA GPUs, `IPC_LOCK`, root in the container,
  and `unless-stopped` restart policy;
- offline Hugging Face and Transformers operation; and
- bind-mounted compiler caches and a persistent output directory.

The management agent stopped the previously active model service before
starting H3. Its deployment log reported that all images were already
preloaded locally. The container became healthy about 285.8 seconds after the
Compose start; the model's own timestamps reported 279.18 seconds from process
startup to ready.

The image labels identify OpenVDN `vdn-minimax-h3` commit `b8cb28f` and a
patched Diffusers commit `3a2f35d`. Lazycat's modification note says its Thor
changes replace contiguous window-attention query gather/scatter operations
with slices; its own three-profile byte-for-byte checks reported 1.06% to
1.86% end-to-end improvement.

The runtime uses Python 3.12.13, Torch 2.11.0, Diffusers `0.40.0.dev0`,
Transformers 5.12.1, Triton 3.6.0 and FlashAttention 2.8.4. The container image
inherits a vLLM-oriented base, but the H3 service itself is a custom Python
`ThreadingHTTPServer`, not vLLM.

## Model assembly

The image embeds approximately 78 GB under its VDN workspace:

| Component | Approximate size |
| --- | ---: |
| H3-Base transformer, 14 safetensor shards | 62 GB |
| Video VAE, 3 shards | 9.8 GB |
| Audio VAE | 578 MB |
| VDN linear-attention branch | 4.0 GB |
| Default LoRA | 319 MB |
| Eight-step turbo LoRA | 813 MB |
| Three pre-encoded prompts | 29 MB |

At startup it builds the `stage-dmd-step-250` VDN checkpoint on top of
H3-Base, loading 800 branch tensors and merging 571 LoRA pairs. It fixes
inference to eight model evaluations with `video_shift=12.0` and
`audio_shift=3.0`, selects the decomposed window-softmax path on Thor, and
converts 363 wide Linear modules to FP8 E4M3. The service warns that FP8
changes the sample, so a seed does not reproduce the BF16 render.

This differs from the complete upstream H3 system. The inspected package
contains only the text-to-audio-video VDN path; it does not expose first/last
frame or reference image, video, or audio inputs.

## API and capability limits

The service listens directly on a host-network port. Its API has health,
model, capability, asynchronous generation, task query, cancellation and
video-download routes. It also provides thin synchronous
`/v1/chat/completions` and `/v1/completions` adapters that return a video URL
as text.

The implementation has one GPU worker and a 32-entry in-memory queue. Tasks
are serialized. Task state is lost on restart, while MP4 and JSON files remain
on disk. There is no output-retention cleanup in the service.

The inspected API does not validate an authorization header. Requests with a
missing or incorrect token reached the same routes. It also provides no TLS,
rate limit or per-user isolation; access control must therefore be enforced
outside this process.

Three output profiles are hard-coded:

| Profile | Frames | Nominal duration |
| --- | ---: | ---: |
| 640 x 384 | 124 | 5.17 s |
| 832 x 480 | 124 | 5.17 s |
| 640 x 384 | 243 | 10.13 s |

The service includes three pre-encoded prompts. Although its capability route
advertises arbitrary text prompts, the image lacks the Qwen3-VL-32B
`processor`, `tokenizer` and `text_encoder` directories required by its own
prompt-encoding code, and offline mode is enabled. An arbitrary prompt is
therefore accepted as a task but fails when the worker tries to load the
missing conditioner. Only the bundled prompt embeddings were confirmed usable.

## Performance measurements

All measured tasks used the bundled `example_2` prompt, seed 42 and eight model
evaluations. Tasks were submitted serially to an already-ready service, so the
reported wall time excludes queue wait. The first 640 x 384 request invoked a
TorchInductor compile worker. The first request at each previously unused shape
also had a slower first denoising step, so it is separated from subsequent
same-shape runs below.

| Profile | First request at shape | Subsequent same-shape wall times |
| --- | ---: | --- |
| 640 x 384, 124 frames | 81.247 s | 76.973, 76.781, 76.942, 77.013, 76.942 s |
| 832 x 480, 124 frames | 125.651 s | 124.644, 124.761 s |
| 640 x 384, 243 frames | 152.424 s | 151.485, 151.521 s |

The five post-first-request 640 x 384 samples have a 76.942-second median,
76.781-to-77.013-second range and 0.11% sample coefficient of variation. The
two post-shape-compile repeats averaged 124.703 seconds at 832 x 480 and
151.503 seconds for the 243-frame profile. Those two-sample sets show low
spread but are too small for a robust distribution.

The profile-level summary uses the five post-first-request 640 x 384 samples.
For the other profiles it uses all three tasks, so their ranges include the
first new-shape task:

| Profile | Measured output | Wall median (range) | Denoise median | Decode/encode median | Peak CUDA allocation median | Wall/output ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 640 x 384, 124 frames | 5.175 s | 76.942 s (76.781–77.013) | 65.425 s | 11.514 s | 60.813 GiB | 14.87 x |
| 832 x 480, 124 frames | 5.175 s | 124.761 s (124.644–125.651) | 102.611 s | 22.146 s | 61.056 GiB | 24.11 x |
| 640 x 384, 243 frames | 10.125 s | 151.521 s (151.485–152.424) | 128.444 s | 23.074 s | 61.138 GiB | 14.97 x |

`ffprobe` confirmed 24 FPS H.264 video and 32 kHz stereo AAC audio for every
profile. Repeats within each profile were byte-for-byte deterministic:

| Profile | File size | SHA-256 |
| --- | ---: | --- |
| 640 x 384, 124 frames | 642,937 bytes | `7ac485b6a0918c7f89758506bf90a413bc9577340791a030e68bc8ec15843cd1` |
| 832 x 480, 124 frames | 1,123,394 bytes | `084b7f4405df7dac3b80e47a9580f0d4f5e73860d4d9a96d998bc942ec2df05d` |
| 640 x 384, 243 frames | 1,342,845 bytes | `2d6455a80fcba30f5b35da2a1d85077a660fc9f327d276a55799bff74b0672a0` |

A 190-s, one-second-resolution `nvidia-smi` window covered the remainder of
one 640 x 384 run, the following full run and the idle gaps. Among 127 samples
with non-zero GPU utilization, average GPU utilization was 97.57% and average
reported GPU power was 59.69 W. The highest observed temperature was 67 C;
the graphics-clock query reported up to 1,386 MHz. This is GPU power, not
whole-board input power, and the telemetry did not expose fan RPM or unified
memory usage. The runtime's own CUDA peak-allocation measurements are used in
the table above.

The 640 x 384 five-second median is about 2.03 times the manufacturer's
38-second product-page figure recorded in the
[Thor overview](../../thor.md#manufacturer-published-performance-snapshot).
The 832 x 480 median is about 1.04 times its two-minute figure. The local
service exposes a 10.125-second 640 x 384 profile, not the page's 15-second
profile, so those times are not compared. The manufacturer's exact prompt,
image build, cache state, timing boundary and output validation remain unknown;
these ratios are observations, not controlled regression results.

## Measurement status and follow-ups

The fixed bundled prompt now has a repeatable 640 x 384 steady-state baseline
and a three-profile timing matrix. It does not establish arbitrary-prompt
quality or the performance of the complete upstream H3 system. Useful next
checks are:

1. Repeat after a controlled service restart to separate cache restoration,
   model startup, first-request compilation and shape-specific compilation.
2. Add one or more post-shape-compile repetitions for the other two profiles
   before treating their distributions as stable.
3. Capture whole-board power and fan RPM alongside GPU telemetry.
4. Test a repaired custom-prompt conditioner with a documented prompt set
   before drawing quality conclusions.

## References

- [MiniMax H3 official repository](https://github.com/MiniMax-AI/MiniMax-H3)
- [OpenVDN VDN-Minimax-H3](https://github.com/OpenVDN/vdn-minimax-h3)
- [OpenVDN VDN-H3 weights](https://huggingface.co/OpenVDN/vdn-minimax-h3)
- [Lazycat AI compute capsule product page](https://lazycat.cloud/ai-pod)
