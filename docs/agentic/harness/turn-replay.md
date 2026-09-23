# 截断与中断回合的重放：一次 Qwen3.8 在 Pi 中“迷失”的排查

日期：2026-09-22。环境：pi 0.85.1，经 LiteLLM 调用 Thor 上 SGLang 部署的
Qwen3.8-27B；对照 opencode 1.18.3、DeepSeek Harness 0.1.7-alpha.1 与 Codex
（`openai/codex` main `99784bd`）。

## 现象

在 pi 中让 Qwen3.8-27B 实现一个脚本。模型把整份代码写在思考里，连续 7 个回合
都以 `stopReason: length` 结束：输出 8192 token 全部是思考，没有正文和工具调用，
TUI 显示 “Response was truncated before completion”。每次回复“继续”后，请求的
输入 token 只增加约 6 个，模型从相同上下文重新规划同一件事，看起来像迷失在任务里。

## 原因

1. **输出上限过低。** 客户端模型配置的 `maxTokens` 为 8192，pi 每次请求都以
   `max_tokens` 发送。服务端没有单独的输出上限，只受上下文长度限制。
2. **只有思考的回合不会重放。** pi-ai 的 `openai-completions` 适配器把思考放进
   `reasoning_content`，随后跳过“既没有正文也没有工具调用”的助手消息，而这个判断
   不看 `reasoning_content`。这是有意的兼容处理：部分 OpenAI 兼容服务会拒绝空
   content 的 assistant 消息。
3. **中断的回合整条丢弃。** pi 在转换历史时丢弃所有 `aborted` 和 `error` 回合，
   不论其中是否已有正文或工具调用，也不告诉模型发生过中断。

Qwen3.8 的 chat template 默认保留历史思考：实测 `chat_template_kwargs` 能经
LiteLLM 传到 SGLang，不传时的行为与 `preserve_thinking: true` 相同。所以丢失
只发生在 harness 这一层。

## 各 harness 的行为

经记录请求的代理实测（Codex 为源码阅读）：

| Harness | 只有思考的截断回合 | 思考阶段手动中断 |
|---|---|---|
| pi 0.85.1 | 丢弃 | 丢弃，无提示 |
| opencode 1.18.3 | 保留：`content: ""` 加完整 `reasoning_content` | 丢弃，无提示 |
| DeepSeek Harness | 丢弃（OpenAI 兼容路由底层同样是 pi-ai 0.85.1） | 丢弃，无提示 |
| Codex | 不发送 `max_output_tokens`，几乎不截断；`response.incomplete` 按流错误处理 | 丢弃未完成的项，写入 `<turn_aborted>` 标记 |

之前使用 opencode 与 Codex 时没有遇到这个问题：前者会保留截断回合，后者从设计上
避免截断，而 Qwen3.8 长思考的习惯恰好把差异暴露出来。

## 处理

- **输出上限设为 65536。** pi 无法省略 `max_tokens`，它发送的是
  `min(maxTokens, 上下文长度 − 估算提示长度 − 4096)`。SGLang 会拒绝提示与
  `max_tokens` 之和超过上下文长度的请求，而 pi 按每 4 个字符 1 个 token 估算，
  会明显低估中文。若把上限设为整个上下文，读入一个较大的中文文件就可能被拒。
  取 65536 时，只有上下文超过约 19 万 token 才会触及这个问题；LiteLLM 2400 秒的
  超时本来就把单轮输出限制在约 6 万 token（按约 25 token/s 计），效果上等同于不设上限。
- **中断标记。** 新增 pi 扩展，在每个被中断的助手回合后插入与 Codex 措辞一致的
  `<turn_aborted>` 用户消息，让模型知道上一轮被用户有意中断。
- **提示词。** 共享 AGENTS.md 增加一条：思考也计入输出上限，不要在思考里起草整份
  文件，应直接用工具分次写入。
- 未处理：只有思考的截断回合依然不会重放。上限足够大时，截断基本只会以超时
  错误的形式出现，与 Codex 的处理一致。上游相关讨论见
  [earendil-works/pi#9602](https://github.com/earendil-works/pi/issues/9602)。

模型配置与扩展位于私有仓库（`modules/home/coding-agent.nix`、
`modules/home/pi-turn-aborted/`）。
