# AI 模型

本地模型优先承担日常自动化；遇到超出能力、长时间无法收敛或影响较大的任务，再转交更强的云端 Agent。云端模型也用于需要更谨慎判断的任务。这里记录模型接入和本地推理的现状；模型能力不能仅由上下文长度或配置表推断。
紧急情况： 订阅模型全部耗尽且无法Reset，去multica将对应agent临时改为使用本地模型。

## 接入结构

```text
Agent（Pi / OpenCode 等）
  → 万象集群 LiteLLM（模型路由、虚拟密钥）
    → Thor NixOS / SGLang（本地主力）
    → 懒猫 AI Pod 应用后端（保留的对照路由）
    → 云端模型供应商
```

LiteLLM 运行在万象集群，声明见 `wanxiang/kubernetes/apps/ai/litellm/`；模型行由私有仓 `terraform/litellm-wanxiang/models.json` 管理，客户端模型列表由私有仓 `modules/home/coding-agent.nix` 配置。公开仓 `modules/home/pi.nix` 提供 Pi 的通用接入方式，凭据在运行时从环境变量或 SOPS Secret 读取，不写进模型文档。路由清单只是期望配置，不等于实时健康检查。

## 本地推理

| 客户端模型 ID | 后端与用途 | 已确认状态 |
| --- | --- | --- |
| `thor/qwen3.8-27b` | Thor 上的 NixOS/SGLang，Qwen3.8 27B；日常主力 | 2026-09 的部署与工具调用验证有记录；当前在线状态未在本文重新核验 |
| `thor/qwen3.8-auto` | LiteLLM 按顺序尝试 NixOS/SGLang、懒猫应用 27B、懒猫应用 Flash Next | 三条后端均有 Terraform 路由；故障切换行为及各后端当前可用性仍需实测 |
| `lcai/qwen-3.8-27b-uncensored`、`lcai/qwen-3.8-flash-next-uncensored` | 懒猫 AI Pod 应用提供的对照后端 | 保留了模型路由；不把它视为唯一设备的长期生产方向 |

Thor 当前的生产声明位于私有仓 `hosts/personal/fixed/thor/inference.nix`：SGLang 以本地模型快照启动 Qwen3.8 27B，使用 DFlash2 block16 推测解码；单请求上下文 262144 token，最多 4 个活动生成共享 270336 token 的驻留池。因此“4 并发”不表示四个请求都能同时占满 256K 上下文。LiteLLM 经 Tailnet 连接 Thor，后端不另设独立 API key；访问控制依赖网络边界和 LiteLLM 的虚拟密钥。

已记录的验证覆盖普通文本、流式响应、JSON 输出、工具调用及工具结果续接。长上下文冷启动可能需要很久；客户端、LiteLLM 的请求/流超时均需匹配。Pi 的相关超时和被中断请求处理见 [turn-replay](../harness/turn-replay.md)。推理服务的部署与运行约束见 [本地推理](../../inference/README.md)，模型评估见 [Thor 模型实验](../../inference/thor/README.md#模型实验)。

唯一一台算力舱已决定以 NixOS/SGLang 为长期方向：此前官方 AI Pod 的 vLLM 在当时负载下吞吐未优于自建实现。若购入第二台，可保留官方系统，用于对照测试和官方 AI Pod 应用对接；这不是现有第二台设备。设备背景见私有仓 `docs/inventory/guanggu/lazycat-aipod/2026-09-17-firmware.md`。

## 其他算力与待办

- Mac mini M4 的 27B 级 oMLX 服务已下线；继续作为 ASR、TTS、Embedding 或中小模型的候选宿主，尚未定稿。历史容量测试见 [`oMLX 记录`](../../inference/omlx-model-capacity.md)。
- 其他 GPU 设备仍以硬件规划或实验为主，不计入现有生产模型容量。详见 [算力盘点](../../inference/ai-compute-inventory.md)；设备硬件事实以两仓的 inventory 为准。
- [WIP] 分别验证本地模型在实际 Agent 任务中的收敛、工具使用和转交阈值。Qwen3.8 27B 高思考强度下可能长时间不收敛，这是使用观察，不是已量化的模型结论。
- [WIP] ASR、TTS、Embedding/Rerank、生图、生视频的模型和落机分配。
