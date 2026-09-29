# AI 算力设备盘点

记录可用于模型推理、生成类负载的宿主机与 GPU、约束和部署计划。以 2026-09-15 盘点为基础；Tesla P4 的位置按 [m920x 设备记录](../inventory/taichu/m920x.md)更新至 2026-09-23，NUC 和 Gen10 Plus 的角色按后续用户说明修正，2026-09-28 更新 Gen10 Plus 的供电故障与 NVIDIA 驱动状态，2026-09-29 将 A2000 排除出关键负载容量并调整本地模型能力优先级。未注明重新核验的状态仍需现场确认。生产部署见 [Thor 推理](thor/thor-inference.md)，oMLX 历史容量见 [oMLX 记录](omlx-model-capacity.md)。

## 宿主机

| 主机 | 硬件 | 模型负载角色 | 备注 |
| --- | --- | --- | --- |
| thor | Jetson AGX Thor，Blackwell GPU，128 GiB 统一内存 | 主力 LLM/VLM：生产 SGLang Qwen3.8 27B；按需运行实验实例 | 生产实例配置 256K 上下文、最多 4 个活动生成，但不代表 4 路均可占满 256K。重负载需与生产实例互斥，内存守护以 12 GiB 可用内存为红线 |
| beacon-mac-mini-m4 | Mac mini M4，32 GiB 统一内存 | 27B 级 oMLX 服务已于 2026-09 下线；作为 Embedding、ASR、TTS 的首选验证平台 | 先验证 Embedding，再按实际语音数据验证 ASR、TTS；磁盘权重待手动清理 |
| m920x | x86 NixOS、KVM，太初集群 | Tesla P4 实验宿主 | P4 已装机并被驱动识别；推理负载和便携 PD 电源下的稳定性尚未验证。A2000 在本机持续负载下同样整机断电（与 gen10plus 同类供电问题），且无 IPMI 级遥测 |
| microserver-gen10plus | HPE MicroServer Gen10 Plus，x86 NixOS、KVM | 不承担关键模型负载；仅保留短时、可中断实验用途 | NVIDIA 驱动缺失待重建；A2000 满载会触发主板 P12V 稳压器 Critical 故障并断电，200 W → 300 W 换电源仍未解决（2026-09-28） |
| NUC9 | x86，旧 TrueNAS 设备 | 暂无推理负载 | 尚未接管，目前没有显卡 |
| NUC11 | x86，Windows，Titan RTX 24 GiB | 当前游戏机；非生产推理 | 尚未由 NixOS 接管 |

## GPU

| 卡 | 显存 | 位置 | 计划与限制 |
| --- | --- | --- | --- |
| RTX A2000 | 12 GiB | microserver-gen10plus | Ampere（sm_86），可用 NVIDIA 开源内核模块；驱动缺失需重建。持续负载在 gen10plus 与 m920x 上均会导致整机断电，已验证不能承担关键负载，也不计入可用推理容量；仅保留短时、可中断的兼容性实验用途 |
| Tesla P4 | 8 GiB | m920x（2026-09-23 设备记录） | 驱动已识别，推理及 PD 供电稳定性待验证；仅支持私有内核模块，可探索 mediated vGPU/KVM |
| Titan RTX | 24 GiB | NUC11 | 游戏优先，空闲跑图；非生产用途 |
| Quadro K600 | — | 已退役 | 无 NVDEC，不用于转码 |

## 约束

- A2000 可使用 NVIDIA 开源内核模块，P4 需要私有模块；不能在同一内核中混用两种模块。两卡目前不在同一宿主机。
- gen10plus 供电问题未解决：原装 HP DC 圆孔外置电源仅 200 W，A2000 负载会致整机断电；已换 Alienware 300 W，2026-09-28 仍复现——iLO 报 `Runtime Fault, System Board, P12V Main/AUX Regulators (10h)` 并断电（长时间游戏与持续推理均会触发；此前 vLLM 跑 GLM-7B 短请求 webchat 未见问题）。RAID5 与风扇、温度、内存、存储均正常，限制指向主板 12V 稳压供电链路而非电源额定功率。另：gen 27–37 的内核模块均无 `nvidia.ko`，此前 `nvidia-smi` 可用是旧模块在 `switch` 后残留，重启即失效；恢复 GPU 需带私有仓 NVIDIA 模块重建。详见 [Gen10 Plus 设备记录](../inventory/guanggu/microserver-gen10plus/readme.md)。
- A2000 的持续负载供电问题不是 gen10plus 独有：m920x 装 A2000 同样整机断电，症状一致，但只有 Intel AMT、缺少 iLO/IPMI 级遥测。详见 [m920x 设备记录](../inventory/taichu/m920x.md)。
- Thor 的 128 GiB 统一内存与宿主共享；生产 SGLang 常驻约 70–90 GiB。新增重模型需停生产实例或按需运行实验实例；轻量 ASR、TTS、Embedding 合计低于 5 GiB 时可作为共存候选，尚非已部署结论。
- M4 的 32 GiB 内存不适合同时承载更多 27B 级负载；oMLX 已移出系统配置，重新部署需恢复相关模块并评估 `iogpu.wired_limit_mb`。

## 本地模型能力补全顺序

2026-09-29 将近期优先级调整为 **Embedding → ASR → TTS → Rerank**：

1. **Embedding**：先在 M4 部署轻量候选并接入 Memoh，以 graph-only 为基线。使用 100–300 条真实查询及对应 memory ID 组成检索集，覆盖中文、英文、中英混合、别名、主机名、型号、路径和时间关系；比较 Recall@5/10/20、MRR、nDCG@10 与 p50/p95 延迟。
2. **ASR**：从 Paseo 与 Agent 的真实短指令建立语料，人工录制 30–60 分钟作为主测试集。除中文 CER、英文 WER 和延迟外，单独统计主机名、CLI、模型名、数字等技术实体的识别准确率。合成音频只能用于扩充和回归，不替代真实录音。
3. **TTS**：在 ASR 输入链路稳定后测试。候选需覆盖中文、英文、中英混合、数字和缩写；记录首帧音频延迟、实时率、自然度，以及是否确实需要音色克隆或语气控制。
4. **Rerank**：暂不部署。只有当相关结果经常已进入 Top 20、但 Top 5、MRR 或人工排序仍不理想时再引入；无法召回的内容优先通过 Embedding、分块和查询构造解决。

M4 是上述轻量能力的首选验证平台。P4 只有通过推理负载与 PD 供电稳定性验证后，才可作为 ASR 等成熟 CUDA 负载的候选；A2000 仅用于可中断的兼容性实验；Thor 保持主力 LLM/VLM 角色。

## 已退役负载与清理

- 2026-09 食品卫生事件筛查流程已废弃：曾使用 Titan RTX 上的 LMStudio 文本模型，以及 M4 上的 Gemma-4-31B 图片复核 Agent。
- 2026-09-15 仓库侧已清理相关本地模型条目、图片复核 Agent、M4 的 oMLX 服务配置，以及 LiteLLM Terraform 资源定义和 import。网关中的旧模型行与 Terraform state 仍需手动清理，不能把代码删除等同于运行时清理完成。

## 待办

- [ ] 手动删除 LiteLLM 网关中的 4 条旧模型行（Qwen3.8-27B-4bit、gemma-4-26b-a4b、gemma-4-31b、gemma-4-e4b）并清理 Terraform state；相关资源曾设 `prevent_destroy = true`，不能直接依赖 apply 删除。
- [ ] 手动清理 M4 `~/.exo/models` 权重，包括保留作回退的旧 Qwen3.6。
- [ ] 解决 gen10plus 主板供电（P12V 稳压器）在 A2000 持续负载下触发 Critical 故障的问题；200 W 原装与 300 W 替换电源均不足。修复前不再为 A2000 规划关键负载。
- [ ] 修复 gen10plus 的 NVIDIA 驱动（gen 27–37 均无 `nvidia.ko`，需带私有仓 NVIDIA 模块重建部署）；后续 A2000 测试仅用于兼容性与故障定位。
- [ ] 在 m920x 验证 P4 推理负载和 PD 电源稳定性；按需开展 vGPU 实验。
- [ ] 评估旧 TrueNAS 设备 NUC9 的接管需求；目前无显卡，不计入 GPU 推理容量。
- [ ] 在 M4 建立 Embedding 基线并接入 Memoh；先测轻量候选，只有真实检索集显示质量不足时再测试更大模型。
- [ ] 建立 ASR 真实录音集和 TTS 典型文本集，按统一指标比较候选模型；完成 Embedding 后依次验证 ASR、TTS。
