# 模型来源与模型列表

## Models @ Beacoworks

Beacoworks模型 通过 AI 网关提供。

查看可用模型：

```bash
opencode models beacoworks
```

已配置的模型 ID：

- `beacoworks/dashscope/qwen3.7-max` - Qwen3.7 Max
- `beacoworks/dashscope/qwen3.6-flash` - Qwen3.6 Flash
- `beacoworks/deepseek/deepseek-v4-flash` - DeepSeek V4 Flash
- `beacoworks/deepseek/deepseek-v4-pro` - DeepSeek V4 Pro
- `beacoworks/minimax/MiniMax-M3` - MiniMax M3
- `beacoworks/moonshot/kimi-k2.6` - Kimi K2.6
- `beacoworks/moonshot/kimi-k2.7-code` - Kimi K2.7 Code
- `beacoworks/xiaomi_mimo/mimo-v2.5` - MiMo V2.5
- `beacoworks/xiaomi_mimo/mimo-v2.5-pro` - MiMo V2.5 Pro
- `beacoworks/zai/glm-5.2` - GLM-5.2
- `beacoworks/Qwen3.6-27B-4bit` - Qwen3.6 27B 4bit
- `beacoworks/Qwen3.6-35B-A3B-4bit` - Qwen3.6 35B A3B 4bit
- `beacoworks/gemma-4-26b-a4b-it-4bit` - Gemma 4 26B A4B IT 4bit
- `beacoworks/gemma-4-31b-it-4bit` - Gemma 4 31B IT
- `beacoworks/gemma-4-e4b-it-4bit` - Gemma 4 E4B IT

如果用户没有指定模型，基础连通性检查优先用 `beacoworks/deepseek/deepseek-v4-flash`。选择高成本或特定任务模型前先询问用户。

对 Beacoworks 网关来说，公司网关的价格和可用性是准确信息来源。公开厂商价格或 OpenRouter 价格只能作为参考，可能与公司网关不一致。

## OpenAI

个人订阅或 ChatGPT Pro 支持的 OpenAI 模型。

OpenAI 订阅模型默认优先使用 Codex CLI。只有当用户明确要求 OpenCode、需要 OpenCode 特定的工作流或会话能力，或需要比较 OpenCode 与 Codex 时，才通过 OpenCode 调用 OpenAI。

Codex CLI 模型 ID：

- `gpt-5.5`
- `gpt-5.3-codex-spark`，用于大批量或快速编码任务

OpenCode provider-qualified 模型 ID：

- `openai/gpt-5.5`
- `openai/gpt-5.3-codex-spark`，用于大批量或快速编码任务
- `openai/gpt-5.4-mini`，如果列表中存在，可用于较低成本连通性检查

不要使用 `gpt-5.5-pro` 或 `openai/gpt-5.5-pro`。它只能在网页端使用，Codex CLI 和 OpenCode 都不可用。

使用 OpenAI-backed CLI 时，不要把成本或推理强度当作绕过数据策略的理由。
