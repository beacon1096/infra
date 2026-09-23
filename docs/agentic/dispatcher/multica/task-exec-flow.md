# Multica 任务执行

Multica 负责工单、任务运行和 Agent 身份；Coder 提供 `/home/coder/workspace` 工作目录及持久化的 `/home/coder`。工作区启动时运行 `multica daemon start`，由 daemon 接收任务并启动实际 agent。Pi、Codex 等 harness 负责当前运行的模型与工具调用，不代替 Multica 管理工单生命周期。

```text
工单 / Autopilot → Multica 服务创建运行 → Coder 工作区的 daemon 接收任务
                                      → agent 在任务上下文内执行、读取/更新工单
                                      → 交付审查、完成、转交或标记 blocked
```

工单、运行与工作区不是同一个对象。一次工单可以有多个运行；一个持久工作区也可能留下其他任务的文件或脏分支。接手时应先确认工单 ID、当前运行 ID、预期仓库和实际工作目录，再读取交接与现有改动；不要靠目录名猜任务归属。仓库模板只声明 Coder 默认工作目录，Multica 为每次运行建立的具体 checkout 结构尚未从固定 `0.4.24` 环境独立核验。

## CLI 与身份边界

工作区镜像固定安装 `multica` CLI `0.4.24`。仓库启动脚本明确使用 `multica daemon start` 和 `multica daemon status`。Multica 上游 [CLI 文档](https://github.com/multica-ai/multica/blob/main/apps/docs/content/docs/cli.mdx)还列出工单查询、评论、状态、运行记录、Agent 和 Autopilot 等命令；该页面跟随上游 `main`，不能直接证明本地固定版本支持每项子命令。任务中需要操作时，先在同一工作区运行 `multica --version` 与相应的 `multica <命令> --help`，优先使用结构化输出，不将模型生成的任意参数拼成高权限命令。

2026-09-14 的本机 Codex 调查曾取回另一 Agent 对 Multica `0.4.24` 的回答：平台操作主要依赖任务作用域的环境身份和 `multica` CLI/API；当时的 Pi adapter 每次运行启动独立 CLI 进程，而非驻留 RPC。该会话问的是 Pi 接入，不是“工作区结构与 CLI 功能”的自述；后者在本机 Codex 记录中尚未确认。因此这里只采纳与[已有 Pi 调查](../../harness/research.md#multica-后续调查对分工的修正)一致的边界结论，不编造任务专属目录布局。

正常工单的转交、审查、完成或 blocked，由任务目标和验证结果决定，不另设复杂的统一完成标准。Renovate 的自动合并是特例：Agent 提供审查结论，n8n 用隔离的凭据核对 PR、门禁和精确提交后才合并，详见 [合并门禁](../../workflow/infra-ops/renovate-multica-gate.md)。
