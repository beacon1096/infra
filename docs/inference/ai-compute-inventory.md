# AI 算力设备盘点

记录可用于模型推理、生成类负载的宿主机与 GPU、约束和部署计划。以 2026-09-15 盘点为基础；Tesla P4 的位置按 [m920x 设备记录](../inventory/taichu/m920x.md)更新至 2026-09-23，NUC 和 Gen10 Plus 的角色按后续用户说明修正。未注明重新核验的状态仍需现场确认。生产部署见 [Thor 推理](thor/thor-inference.md)，oMLX 历史容量见 [oMLX 记录](omlx-model-capacity.md)。

## 宿主机

| 主机 | 硬件 | 模型负载角色 | 备注 |
| --- | --- | --- | --- |
| thor | Jetson AGX Thor，Blackwell GPU，128 GiB 统一内存 | 主力 LLM/VLM：生产 SGLang Qwen3.8 27B；按需运行实验实例 | 生产实例配置 256K 上下文、最多 4 个活动生成，但不代表 4 路均可占满 256K。重负载需与生产实例互斥，内存守护以 12 GiB 可用内存为红线 |
| beacon-mac-mini-m4 | Mac mini M4，32 GiB 统一内存 | 27B 级 oMLX 服务已于 2026-09 下线；待分配新负载 | ASR、TTS、Embedding 或中小模型为候选；磁盘权重待手动清理 |
| m920x | x86 NixOS、KVM，太初集群 | Tesla P4 实验宿主 | P4 已装机并被驱动识别；推理负载和便携 PD 电源下的稳定性尚未验证 |
| microserver-gen10plus | HPE MicroServer Gen10 Plus，x86 NixOS、KVM | 已安装 A2000；电源升级后可运行推理负载和长时间游戏 | 当前启动环境的 NVIDIA 驱动未工作，GPU 推理暂不能视为可用 |
| NUC9 | x86，旧 TrueNAS 设备 | 暂无推理负载 | 尚未接管，目前没有显卡 |
| NUC11 | x86，Windows，Titan RTX 24 GiB | 当前游戏机；非生产推理 | 尚未由 NixOS 接管 |

## GPU

| 卡 | 显存 | 位置 | 计划与限制 |
| --- | --- | --- | --- |
| RTX A2000 | 12 GiB | microserver-gen10plus | 电源已升级并装卡；当前启动环境驱动未工作，需修复后再验证推理；Ampere，可用 NVIDIA 开源内核模块 |
| Tesla P4 | 8 GiB | m920x（2026-09-23 设备记录） | 驱动已识别，推理及 PD 供电稳定性待验证；仅支持私有内核模块，可探索 mediated vGPU/KVM |
| Titan RTX | 24 GiB | NUC11 | 游戏优先，空闲跑图；非生产用途 |
| Quadro K600 | — | 已退役 | 无 NVDEC，不用于转码 |

## 约束

- A2000 可使用 NVIDIA 开源内核模块，P4 需要私有模块；不能在同一内核中混用两种模块。两卡目前不在同一宿主机。
- gen10plus 原装电源下曾出现供电不足，A2000 负载导致显卡异常、整机断电；电源现已升级、A2000 已安装。2026-09-24 只读检查发现显卡在 PCI 总线上，但当前启动的内核模块目录没有 `nvidia` 模块，`nvidia-smi` 失败；恢复驱动之前不能视为当前可用的 GPU 推理宿主。
- Thor 的 128 GiB 统一内存与宿主共享；生产 SGLang 常驻约 70–90 GiB。新增重模型需停生产实例或按需运行实验实例；轻量 ASR、TTS、Embedding 合计低于 5 GiB 时可作为共存候选，尚非已部署结论。
- M4 的 32 GiB 内存不适合同时承载更多 27B 级负载；oMLX 已移出系统配置，重新部署需恢复相关模块并评估 `iogpu.wired_limit_mb`。

## 已退役负载与清理

- 2026-09 食品卫生事件筛查流程已废弃：曾使用 Titan RTX 上的 LMStudio 文本模型，以及 M4 上的 Gemma-4-31B 图片复核 Agent。
- 2026-09-15 仓库侧已清理相关本地模型条目、图片复核 Agent、M4 的 oMLX 服务配置，以及 LiteLLM Terraform 资源定义和 import。网关中的旧模型行与 Terraform state 仍需手动清理，不能把代码删除等同于运行时清理完成。

## 待办

- [ ] 手动删除 LiteLLM 网关中的 4 条旧模型行（Qwen3.8-27B-4bit、gemma-4-26b-a4b、gemma-4-31b、gemma-4-e4b）并清理 Terraform state；相关资源曾设 `prevent_destroy = true`，不能直接依赖 apply 删除。
- [ ] 手动清理 M4 `~/.exo/models` 权重，包括保留作回退的旧 Qwen3.6。
- [x] 升级 gen10plus 电源；已可运行推理负载和长时间游戏。
- [ ] 修复 gen10plus 的 NVIDIA 驱动并验证 A2000 推理，再规划 ASR、TTS、Embedding 或生图用途。
- [ ] 在 m920x 验证 P4 推理负载和 PD 电源稳定性；按需开展 vGPU 实验。
- [ ] 评估旧 TrueNAS 设备 NUC9 的接管需求；目前无显卡，不计入 GPU 推理容量。
- [ ] 为 M4 选定新负载；定稿 ASR → TTS → Embedding/Rerank → 生图 → 生视频的模型选型和落机分配。
