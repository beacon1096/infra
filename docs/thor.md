# Jetson AGX Thor

Device: Jetson AGX Thor T5000 (SM110), also sold as the Lazycat X5.
Detailed records are separated by system and model; dated observations describe
the tested state rather than a guarantee about the current running system.

## System information

- [System and firmware](thor/system.md): NixOS/L4T snapshot, UEFI variables,
  Device Tree boot, display handoff and visibility limits.

## Model experiments

| Model | Record | Scope |
| --- | --- | --- |
| Qwen3.8-27B official Lazycat app | [Official deployment and benchmark](thor/models/qwen3.8-27b-lazycat.md) | App/runtime versions, DFlash2 K16, eight-request scheduling, 5K prefill and 500K context |
| Qwen3.8-27B original NVFP4 | [Retest and launch configuration](thor/models/qwen3.8-27b.md) | Ordinary decode, MTP, DFlash2 and FA4 comparison |
| Huihui Qwen3.8-27B NVFP4 | [Trial and profiling](thor/models/huihui-qwen3.8-27b.md) | Modified target, capability checks, DFlash2 and output-head profiling |
| Qwen3.8 Flash Next official Lazycat app | [Official deployment and benchmark](thor/models/qwen3.8-flash-next-lazycat.md) | App/runtime versions, K16, eight-request scheduling, 5K prefill and 260K context |
| Qwen3.8 Flash Next experimental adaptation | [Deployment and performance](thor/models/qwen3.8-flash-next.md) | SM110 fixes, K3/native GDN, draft-head quantization and target profiling |
| MiniMax H3 VDN FP8 | [Official deployment and benchmark](thor/models/minimax-h3.md) | Lazycat app/runtime composition, API limits and three-profile timing matrix |
| DeepSeek-v4 Flash | [Feasibility review](thor/models/deepseek-v4-flash.md) | Capacity and architecture constraints; not deployed |

Performance results belong to their recorded prompts, runtime revisions and
measurement methods. The model pages retain those conditions and external
references; numbers from different workloads are not a model ranking.

Model serving remains experimental rather than a persistent fleet service.
Private addresses, device identifiers and raw machine inventories are excluded
from these public records.

## Manufacturer-published performance snapshot

Source: the user-provided screenshot headed “懒猫AI算力舱”, recorded here on
2026-09-13 as newer official Lazycat product-page data. The screenshot does
not show a publication date, URL, exact runtime revisions or complete
benchmark methodology. These are manufacturer-published figures, not local
measurements; ranges and workload labels below preserve the displayed claims.
“未审查版” is retained as the manufacturer's model label.

| Advertised model | Hardware | Single-stream decode | Concurrent decode | Prefill | TTFT | Maximum context |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen 3.8 27B | 1 × Thor T5000 | 49–135 TPS | 8 concurrent: 182–423 TPS | 2133 TPS | 5K: 2.49 s | 900K |
| Qwen 3.8 Flash Next 未审查版 | 1 × Thor T5000 | 59–116 TPS | 8 concurrent: 108–313 TPS | 2589 TPS | 5K: 2.5 s | 320K |
| GLM 5.3 Flash | 2 × Thor T5000 | 18 TPS | 16 concurrent: 90 TPS | 4K: 698 TPS | 4K: 5.89 s | 1M |
| DeepSeek V4 Flash Vision 未审查版 | 2 × Thor T5000 | 37.40–39.29 TPS | 8 concurrent: 122.01–124.53 TPS | 4K: 674.70 TPS (18K) / 268.87 TPS (1M) | 5K: 7.22–7.25 s | 1M |

The DeepSeek prefill parenthetical labels `18K` and `1M` are reproduced as
shown; the screenshot does not explain the configuration difference.
Concurrent TPS is listed separately from single-stream decode and must not
be treated as per-request throughput. Advertised maximum context is not a
locally validated capacity or quality result.

The MiniMax H3 card instead reports FP8 video-generation wall times on
**1 × Thor T5000**:

| Resolution | 5-second video | 15-second video |
| --- | ---: | ---: |
| 640 × 384 | 38 s | 226 s |
| 832 × 480 | 2 min | 376 s |
| 1344 × 768 | 4–5 min | 20 min |

The `manateelazycat.github.io` model-adaptation entries linked from the model
pages are the Lazycat manufacturer's technical lead's blog, as clarified by
the user. Attribute them as manufacturer technical reporting. Keep each
dated blog result separate
from this product-page snapshot and from local tests, including model
variants, device counts, prompts, output lengths and timing definitions.
