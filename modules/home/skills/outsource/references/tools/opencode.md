# OpenCode 调用规则

## 使用场景

OpenCode 是通用 CLI，可以调用多个 provider，例如 Beacoworks 和 OpenAI。模型来源、模型 ID 和数据策略见 `../models.md`。

使用 OpenCode 调用 Beacoworks模型 的场景：

- Beacoworks模型无法通过别的方式调用，只能通过opencode使用

使用 OpenCode 调用 OpenAI 的场景：

- 用户明确要求通过 OpenCode 使用 OpenAI。
- 需要 OpenCode 特定的工作流或会话能力。
- 需要与 Codex CLI 对比。

## 基本命令

查看 provider 模型：

```bash
opencode models <provider> </dev/null
```

一次性 prompt：

```bash
opencode run -m <model> 'Reply exactly: ok' </dev/null
```

示例：

```bash
opencode run -m beacoworks/deepseek/deepseek-v4-flash 'Reply exactly: ok' </dev/null
opencode run -m openai/gpt-5.5 'Reply exactly: ok' </dev/null
```

推理强度通过 `--variant` 设置，具体是否生效取决于 provider 和模型：

```bash
opencode run -m <model> --variant minimal 'Reply exactly: ok' </dev/null
opencode run -m <model> --variant high 'Reply exactly: ok' </dev/null
```

常规检查优先使用 `minimal`、`low` 或默认值；只有确实需要时使用 `high`。除非用户明确要求，否则避免使用 `max`。

## 附件

`--file` / `-f` 是可重复的数组参数。位置提示词必须放在第一个附件参数之前；如果把提示词放在附件参数之后，当前 CLI 会继续把它解析为文件路径并报 `File not found`，模型不会收到请求。

```bash
opencode run 'Describe the attached images.' \
  -m <model> \
  --file=first.jpg \
  --file=second.jpg </dev/null
```

多附件时重复使用 `--file=<path>`。不要使用“所有 `--file` 在前、提示词在末尾”的写法。

食品安全事件的图片复核使用无工具的 `image-verifier` Agent。显式设置标题，避免为新会话额外调用一次模型生成标题：

```bash
opencode run --pure \
  --agent image-verifier \
  --title image-verifier \
  -m beacoworks/gemma-4-31b-it-4bit \
  '复核所附图片。' \
  --file=event.jpg </dev/null
```

每次只复核一个事件和 1–3 张图片。该 Agent 不用于搜索文件或读取聊天记录；主 Agent 应先选出相关图片和必要上下文，再作为附件和提示词传入。

## 会话

保存并恢复会话：

```bash
opencode run -m <model> --format json --title '<title>' 'Start the task...' </dev/null | tee /tmp/opencode-work.jsonl
jq -r 'select(.sessionID) | .sessionID' /tmp/opencode-work.jsonl | tail -n 1
opencode run -m <model> --session <session-id> 'Continue the previous task from where it left off.' </dev/null
```

继续最近会话：

```bash
opencode run -m <model> --continue 'Follow-up message' </dev/null
```

## 验证

```bash
opencode providers list </dev/null
opencode models <provider> </dev/null
opencode run -m <model> 'Reply exactly: ok' </dev/null
```

## 已知问题

OpenCode 启动时加载 MCP server 工具 schema，如果 schema 使用了非标准 JSON Schema 格式（如 Go 风格的 `uint`、`uint16`、`uint32`），会输出 `unknown format "uint" ignored in schema at path ...` 等警告。目前已知 `pty-mcp` 的 schema 会触发此问题。这些警告不影响模型调用，可以安全忽略。

## 避免事项

- 不要把 API key 写入 `opencode.json`、shell history、prompt、日志或 Nix store。
- 不要混淆 OpenCode 的 provider-qualified 模型 ID 和其他 CLI 的模型 ID。OpenCode 使用 `openai/gpt-5.5`，Codex CLI 使用 `gpt-5.5`。
