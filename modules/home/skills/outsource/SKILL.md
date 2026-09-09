---
name: outsource
description: 将任务委托给其他 CLI 模型或 Agent。先按模型来源和数据策略选路，再按需读取模型列表与工具子文档。
---

# Skill: outsource

当用户要求调用其他模型、比较模型、运行嵌套 Agent、使用 CodePlan、Cursor Agent、Codex，或通过 OpenCode 调用非默认 provider 时，使用这个 skill。

这个 skill 只负责选路。不要一次性读取所有子文档；先确定模型来源和调用工具，再按需读取对应文件，避免无关工具规则占用上下文。

## 选路规则

用户一般会指定期望使用的模型。如果没有，选择模型来源时，先看用户有无指定 provider，再看能力和成本。

对于 OpenAI 订阅模型，默认优先使用厂家自己的工具：OpenAI-backed Agent 工作默认使用 Codex CLI。只有当用户明确要求 OpenCode、需要 OpenCode 特定的工作流或会话能力，或需要比较 OpenCode 与 Codex 时，才通过 OpenCode 调用 OpenAI。

## 子文档索引

需要模型来源、模型 ID、数据策略细节时，读取：

- `references/models.md`

确定调用工具后，只读取对应工具文档：

- OpenCode：读取 `references/tools/opencode.md`。
- Codex CLI：读取 `references/tools/codex.md`。

通用规则：

- 所有 CLI 调用必须关闭 stdin：在命令末尾追加 `</dev/null`。Codex CLI、OpenCode、cursor-agent 都可能从 stdin 读取追加输入；在非 TTY 环境（Cursor Shell、CI、脚本、嵌套 Agent）中 stdin 不会自动发送 EOF，会导致命令挂起或超时。
- 快速连通性检查使用只读的一次性 prompt，并要求精确返回，例如 `Reply exactly: ok`。
- 实现、仓库分析或验证类任务要视为嵌套 Agent 运行，而不是普通补全请求。
- 非平凡任务使用较长超时，通常按范围、仓库大小、机器资源和网络情况设置为 5-20 分钟。
- 除非明显卡死或用户要求停止，不要急于终止正在运行的嵌套 Agent。
- 有意使用某个 provider 时总是显式传入模型。涉及敏感内容或 provider 特定行为时，不要依赖隐式默认模型。
