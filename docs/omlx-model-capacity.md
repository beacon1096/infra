# oMLX 自部署模型容量

## 初始容量规划

下表记录 Gemma 4 31B dense 迁移到 Mac mini M4 之前的容量规划。常用请求是日常建议范围；oMLX 硬上限用于拒绝超过本机容量的请求，不代表该长度适合日常使用。

| 模型 | 机器 | 常用请求 | oMLX 硬上限 | 输出上限 |
| --- | --- | ---: | ---: | ---: |
| Qwen3.6-35B-A3B | M2 Ultra | 32–64K | 128K | 16K |
| Gemma-4-26B-A4B | M2 Ultra | 16–32K | 64K | 8K |
| Gemma-4-31B dense | M2 Ultra | 8–16K | 32K | 8K |
| Qwen3.6-27B dense | M4 | 8–16K | 32K | 8K |
| Gemma-4-E4B | M4 | 32–64K | 128K | 8–16K |

## 当前部署例外

Gemma-4-31B dense 已迁移到 32GB Mac mini M4。其 4-bit 权重实际占用约 17.9GB，而 oMLX 自动模型内存预算约为 25.6GB，只剩约 7.7GB 供 KV cache、图片编码、预填充和 Metal 运行时使用。因此不要沿用上表中 M2 Ultra 的 32K/8K 硬上限。

M4 上的 Gemma-4-31B dense 使用：

- `max_context_window = 8192`
- `max_tokens = 2048`
- TurboQuant KV Cache：开启，8-bit，Skip Last 开启
- Memory Guard：`aggressive`

LiteLLM 与客户端模型元数据同步声明：

- `max_input_tokens = 8192`
- `max_output_tokens = 2048`

图片复核每次限制为一个事件、1–3 张图片。输入文本和图片 token 尽量控制在约 6K 内，为输出预留最多 2K；常规复核通常只需 512–1024 输出 token。不要在 M4 上为该模型开放 16K、32K 或模型声明的 262K 上下文。

Qwen3.6-27B 与 Gemma-4-31B dense 不能在 32GB M4 上同时常驻，首次切换会包含卸载和加载时间。网关及客户端连通性测试应允许至少 60 秒超时，避免把冷启动误判为不可用。

## Gemma 图片复核 Agent

默认 OpenCode Agent 注入的系统提示和工具定义约为 15.8K token，超过 Gemma-4-31B dense 在 M4 上的 8K 安全窗口。不要通过放宽模型硬上限来容纳与图片复核无关的工具定义。

`modules/home/coding-agent.nix` 声明了专用 `image-verifier` primary Agent。该 Agent 固定使用 `beacoworks/gemma-4-31b-it-4bit`，禁用全部工具、MCP 和 skills，只保留精简的食品安全图片复核提示。调用时同时使用 `--pure`，避免加载外部插件：

```bash
opencode run --pure \
  --agent image-verifier \
  --title image-verifier \
  '复核所附图片。' \
  --file=event.jpg </dev/null
```

显式传入 `--title`，避免 OpenCode 额外调用模型生成会话标题。提示词必须位于第一个 `--file` 之前；多图时重复使用 `--file=<path>`。每次只处理一个事件和 1–3 张图片。

## OpenCode 声明

`modules/home/coding-agent.nix` 中的模型上下文和输出限制应采用当前部署的安全硬上限，而不是上游模型的理论窗口。高级 oMLX 推理开关只记录在本文，不写入 OpenCode 的模型使用提示。
