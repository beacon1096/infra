# Codex CLI 调用规则

## 使用场景

Codex CLI 是 OpenAI 订阅支持的 Agent 工作默认工具，除非用户明确要求使用 OpenCode。

仅在以下场景使用 OpenAI：

- 用户明确要求使用 OpenAI、ChatGPT Pro 支持的模型或 Codex CLI。

模型来源、模型 ID 和数据策略见 `../models.md`。

## 调用方式

只读一次性 prompt：

```bash
codex exec -m <model> --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
```

示例：

```bash
codex exec -m gpt-5.5 --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
codex exec -m gpt-5.3-codex-spark --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
```

推理强度使用 `model_reasoning_effort`：

```bash
codex exec -m <model> -c 'model_reasoning_effort="low"' --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
codex exec -m <model> -c 'model_reasoning_effort="high"' --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
```

评审、解释、模型对比和问答使用 `--sandbox read-only`。只有在用户批准文件编辑时才使用 `--sandbox workspace-write`。除非用户明确要求且外部环境已经沙箱化，否则避免使用 `--dangerously-bypass-approvals-and-sandbox`。

需要由 Codex Agent 执行 SSH、远端构建、远端测试或其他网络/socket 操作时，不要使用普通沙箱模式委托；Codex 沙箱可能拒绝创建 socket，表现为 `socket: Operation not permitted`。这种任务要么由主会话执行远端命令，要么在用户明确批准且外层环境已隔离时使用 `--dangerously-bypass-approvals-and-sandbox`，并在 prompt 中限定目标主机、目录和禁止提交/回滚。

## 会话

恢复会话：

```bash
codex exec resume --last -m <model> 'Follow-up message' </dev/null
codex resume
```

`codex exec resume` 的参数集合不同于新建 `codex exec`。不要在 `resume` 子命令后追加 `--sandbox` 或 `--skip-git-repo-check`；常见报错是 `unexpected argument '--sandbox' found`。需要沙箱/权限模式时，优先新开一次 `codex exec ...`；如果必须恢复会话，只传 `--last`、`-m/--model`、`-c/--config`、可选 session id 和 prompt，并保持 `</dev/null`。

## 验证

```bash
codex doctor
codex exec -m <model> --skip-git-repo-check --sandbox read-only 'Reply exactly: ok' </dev/null
```

## 避免事项

- 不要混淆 Codex CLI 模型 ID 和 OpenCode provider-qualified ID。Codex 使用 `gpt-5.5`；OpenCode 使用 `openai/gpt-5.5`。
