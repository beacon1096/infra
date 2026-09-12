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
| Qwen3.8-27B original NVFP4 | [Retest and launch configuration](thor/models/qwen3.8-27b.md) | Ordinary decode, MTP, DFlash2 and FA4 comparison |
| Huihui Qwen3.8-27B NVFP4 | [Trial and profiling](thor/models/huihui-qwen3.8-27b.md) | Modified target, capability checks, DFlash2 and output-head profiling |
| Qwen3.8 Flash Next NVFP4 | [Deployment and performance](thor/models/qwen3.8-flash-next.md) | SM110 fixes, memory allocation, eager, CUDA Graph and MTP K1 |
| DeepSeek-v4 Flash | [Feasibility review](thor/models/deepseek-v4-flash.md) | Capacity and architecture constraints; not deployed |

Performance results belong to their recorded prompts, runtime revisions and
measurement methods. The model pages retain those conditions and external
references; numbers from different workloads are not a model ranking.

Model serving remains experimental rather than a persistent fleet service.
Private addresses, device identifiers and raw machine inventories are excluded
from these public records.
