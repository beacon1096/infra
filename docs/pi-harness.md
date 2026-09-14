# Pi harness：需求与选型讨论

日期：2026-09-14。状态：架构边界已明确，exec 继续选型；pi-web-access 已部署。
已完成固定版本的隔离 exec/drain 概念验证；exec 原型尚未进入正式配置。
内置行为以本次检查的 Pi 0.85.1 为基线；第三方能力来自调查当日的上游文档，
不代表已验证与该版本兼容。后续实施应固定扩展版本并补充实测结果。

## 背景与已完成基础

目标是为 ChatGPT 订阅和经 LiteLLM 提供的自部署模型构建可逐步扩展的 harness。
用户选择 Pi，要求 coding agent 工具从锁定的 nixpkgs-unstable 引入，
先准备最小 Nix 骨架，再逐项讨论、实现能力。

目前已准备 Pi 包、共享规则入口，以及运行时读取凭据的 LiteLLM provider。
LiteLLM 已完成两种模型的简短真实请求测试；这只证明基本连通与文本响应，
不证明工具调用、长上下文、并发或恢复行为已经验证。
ChatGPT 使用 Pi 原生订阅登录入口，仍待用户首次 OAuth 登录和调用验证。
Linux 配置及相关产物构建通过；macOS 配置求值通过，构建验证受可用 builder 限制。
这些是准备与测试状态，不表示已经全量激活部署。

本文只记录通用需求、机制和选择依据，不包含部署地址、凭据或内部拓扑。
Pi 的扩展入口包括工具、事件、UI、RPC 和 SDK，适合在不 fork 核心的情况下逐步实现。
参考：[Pi README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)。

## 用户输入与判断边界

### 后续明确的架构边界

以下是用户提供的现有使用方式与方向，不是本轮对平台功能的独立验证：

| 场景 | 上层职责 | Pi 的职责 |
| --- | --- | --- |
| 长程、带工单/测试/验收/审核的任务 | Multica 管理任务与长期 agent 身份，Coder workspace 承载运行时。 | 提供模型、工具和基本子任务执行，不再建立身份或工单系统。 |
| 短期 ad-hoc 任务 | Paseo 在个人设备间选择运行设备、harness 和模型。 | 处理当前会话及其工具调用。 |
| 未来近实时聊天 agent | QQ 群 chatbot、代码或 computer use 等尚未规划；倾向由上层平台管理。 | 仍作为基础执行器。 |

已确定：否决 pi-messenger；如果以后需要通用消息通信，优先考虑 Matrix 等上层通道，
而不是 Pi 专用通信网络。基本子代理沿 pi-subagents 方向评估。
edit 使用默认实现；MCP 复用现有 Home Manager 服务配置；
用户继续考察 Pi TaskGraph，本轮重点深入 exec。
Pi `/tree` 可理解为会话历史回溯与分支导航，类似 rewind 的用途，
但它不会自动回滚文件、撤销命令或恢复外部世界状态。

### 初始需求记录

| 议题 | 用户的观察、偏好或问题 |
| --- | --- |
| exec | 使用体验上，Claude Code 可异步执行并在完成后回调；Codex 可异步执行但常需模型轮询，等待时难以停止输出；OpenCode 原生执行会等待进程结束。偏好 Claude Code 式完成通知。 |
| edit | 想了解 Pi 默认编辑方式和生态替代品。预计最弱的常用模型约为自建 Qwen3.8 27B，认为低级工具调用错误应较少。 |
| todo | OpenCode 的待办工具与可见进度有帮助；目前使用 Codex 时缺少满意的同类体验。即使模型记得计划，人也需要能随时查看。希望了解树或图状计划，便于深度优先处理后返回原目标。 |
| subagent | 从触发子代理开始，进一步需要主代理打断、追加指令和代理间通信；认识到其复杂度较高，希望了解现成实现。 |
| web search / fetch | 需要联网搜索和网页读取，优先级靠后。 |
| MCP | 需要连接已有设施。 |
| 后续 | 继续增补议题，最后再对整个 Pi 配置查漏补缺。 |

以上竞品描述是用户当前环境中的使用观察，不是跨版本、跨客户端的产品定论。
尤其不能把某次会话缺少可见 todo，写成所有 Codex 都不存在计划工具；
也不能把宿主是否支持后台完成事件直接归因于模型本身。
本轮核实对象是 Pi，并未逐版本复测三个竞品。

对模型能力的预期也暂列为假设：模型规模不能排除重复文本、过时文件内容、
并发修改或接口歧义造成的错误。选型应看本地任务中的成功率、误改率、重试成本，
不因“模型较强”提前删去工具的确定性校验。

## exec：需要的是完成通知与让出执行权

需要分别检查四件事：实现是否返回 Promise；UI 是否流式显示输出；
工具是否在进程结束前返回任务句柄，让模型继续做其他事；
完成后是否能在模型空闲时唤醒它处理结果。
只有前两项，不满足这里的异步执行需求。

暂定交互目标：短命令直接返回；长命令可转后台并返回稳定任务 ID；
主代理可以继续处理其他任务，也可以结束当前输出、等待完成事件；
完成事件带退出码和输出摘要，完整日志按需读取；保留取消与人工检查入口。
这里的“回调”指 harness 接收进程完成事件并安排后续模型回合，
不是让模型在一次生成中注册任意代码回调。

Pi 0.85.1 的原生模型工具名是 `bash`，接受 `command` 和可选 `timeout`，
没有后台参数或任务 ID；工具等待进程结束才返回。stdout/stderr 可流式更新 UI，
超时或取消会终止进程树，但这仍不满足上面的后台交互目标。
来源：[该版本 bash 源码](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/core/tools/bash.ts)。

Pi 扩展可以用 `sendMessage` 配合 `triggerTurn` 在空闲时唤醒模型；
忙时通过 steering 或 follow-up 队列投递。
这是执行边界上的调度，不是任意时刻抢占正在生成的 token。
来源：[扩展 API](https://pi.dev/docs/latest/extensions)。

| 候选 | 上游描述的能力 | 需要确认 |
| --- | --- | --- |
| [pi-interactive-shell](https://github.com/nicobailon/pi-interactive-shell) | PTY、输入、用户接管、后台和取消；dispatch 模式立即返回，完成后通知；monitor 按事件通知。 | 功能较完整，先测试 dispatch 是否满足普通长命令；zigpty 在 Nix/Linux/macOS 的打包。 |
| [pi-background-work](https://github.com/Davidcreador/pi-background-work) | `/background` 可把已运行的 shell/subagent 转入后台，结束后投递消息。 | 主代理与用户分别如何触发；会话退出、取消及恢复语义。 |
| [pi-background-bash](https://github.com/sshkeda/pi-background-bash) | bash 后台参数、自动后台化和完成唤醒；后续已定位公开源码。 | 下文补充 1.0.1 源码复核；仍不解决 print 模式退出问题。 |

初步结论：Pi 原生 bash 不满足偏好，但扩展机制足够；先评估现成的后台执行，
验证“无需反复轮询、空闲后会被唤醒”再决定是否需要自写小扩展。

### 深入 exec：平台接入决定生命周期

结合上述职责划分，exec 只需管理一次会话内的进程，不必承担长期身份或工单调度。
但“模型停止输出”与“平台结束任务、销毁 Pi 进程”必须分开。

```text
模型启动长命令 → 工具返回任务 ID → 模型继续工作或结束当前回合
                                      ↓
                         Pi 会话仍保持运行，进程仍受管理
                                      ↓
命令退出 → 完成消息入队 → 启动后续模型回合 → 检查结果 → 向平台交付
```

Pi 0.85.1 的 `steer` 等当前 assistant 的整批工具调用结束，再在下一次模型请求前投递；
`followUp` 等工具循环结束。两者都不是抢占正在运行的命令。
空闲时 `triggerTurn` 可以开始新回合，但必须还有存活的 Pi runtime。

`pi -p` / JSON 输出模式会在 `session.prompt()` 返回后清理 runtime，触发
`session_shutdown`。不能把一次性 CLI 当作可无限等待后台完成的宿主。
持久 RPC/SDK 是可选方案，但不是唯一方案：后续发现 awaited `agent_end` 可使扩展
延迟 prompt 完成，并让排队消息触发后续回合，详见后文修正。
平台不能将每一次 `agent_end` 直接解释成整个工单完成。
Multica 的后续调查见下文；Paseo 的 Pi 适配方式仍待核实。
来源：[agent-session.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/core/agent-session.ts)、
[print-mode.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/modes/print-mode.ts)、
[agent-loop.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/agent/src/agent-loop.ts)。

首轮验证应区分：命令已完成但模型尚未读结果；模型空闲但命令仍在跑；
用户取消当前回答；用户明确取消后台任务；平台关闭会话。
进程完成、消息已投递、模型已消费结果，也不能合并成一个状态。
默认可用 follow-up 避免打断独立工作，是否对失败事件使用 steering 留待实测决定。

### pi-background-bash 的进一步复核

用户提供另一模型的调查后，进一步检查 sshkeda/pi-background-bash 当前源码（package 1.0.1）。
后台完成通过 `sendMessage` 的 followUp/triggerTurn 投递；忙时缓存通知，
在 agent_end 后用 setImmediate 尝试发送。但 session_shutdown 明确调用 abortAllJobs，
终止后台进程组并清空待发通知。它没有在 print 退出路径上等待所有后台任务。
来源：[扩展源码](https://github.com/sshkeda/pi-background-bash/blob/main/extensions/background-bash.ts)。

需要修正“退出主要靠 Node 事件循环自然耗尽”的推断：Pi 0.85.1 的 print-mode
在 finally 中显式 disposeRuntime，再刷新 stdout。操作系统进程可能受残留 handle
影响而晚退出，但 runtime 已清理不等于仍能可靠处理任务通知。
历史 issue 的挂住现象不能作为 print 支持后台任务等待的证据。
来源：[print-mode.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/modes/print-mode.ts)。
此前“回合结束就直接退出”的表述应理解为 prompt 真正完成后进入清理流程，
不能忽略 awaited agent_end listener 可以延迟这一时刻，也不保证操作系统进程立即消失。
本轮为源码检查，未执行该第三方扩展；后续实测要检查后台产物、模型消费结果及最终退出，
而不能只观察 PID 是否存活。

### 修正：awaited agent_end 与 pi-subagents headless drain

线索来源：用户转述的 ChatGPT Web 回答，模型 GPT-5.6 Sol，推理档位 High。
该回答指出 pi-subagents/background-work 与 headless agent_end auto-drain 的组合路径。
来源归属与后续源码复核、端到端实测分别记录，不将模型回答本身当作验证结果。

根据这条线索，复核 Pi 0.85.1 与 pi-subagents 已发布 v0.67.0，
确认此前“必须改 core 或采用驻留 RPC 才能等待”的判断过强。
Pi 会 await agent_end listener；AgentSession 在其结束后检查新排入的消息，
通过 agent.continue 继续运行，最后才让最外层 prompt 完成。
因此扩展可以延迟 print 的清理时刻，不需要依赖 Node 残留 handle。
来源：[agent.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/agent/src/agent.ts)、
[agent-session.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/core/agent-session.ts)。

pi-subagents v0.67.0 在无 UI 的 agent_end listener 中 await drainOutstandingWork，
包括当前会话的子代理及 `pi-subagents/background-work` 注册的活跃任务。
这不是 Pi 核心的通用 task lease，却是公开扩展机制组成的实际保活路径。
来源：[注册点](https://github.com/nicobailon/pi-subagents/blob/v0.67.0/src/extension/index.ts#L826)、
[drain](https://github.com/nicobailon/pi-subagents/blob/v0.67.0/src/runs/background/auto-drain.ts)。

桥接并非仅把 running PID 列出来：provider 只提供 id/sessionId，任务从 snapshot 消失
就视为结束，没有结果或通知消费确认。必须在完成后先持久化结果、将 follow-up 排入 Pi，
再移除 active item 并发 wake；尚未入队的完成通知也应计作待完成工作。
不能先移除再 setImmediate 发通知，也不能等模型消费后才移除，否则会与 drain 相互等待。
会话标识应遵循 getSessionFile() 优先、getSessionId() 回退的规则，不能一律填 UUID。
来源：[provider API](https://github.com/nicobailon/pi-subagents/blob/v0.67.0/src/api/background-work.ts)、
[session identity](https://github.com/nicobailon/pi-subagents/blob/v0.67.0/src/shared/session-identity.ts)。

该版本 auto-drain 默认硬期限三十分钟，不是无限等待；超时、取消与扩展错误如何反映到
CLI/平台最终状态仍需实测。main 还存在未发布的提前退出条件，实施应固定版本。
当前结论是“现有机制足够形成实现路径”，不是“已找到开箱即用、所有退出路径可靠的 exec 包”。
pi-background-tasks 的整包编排仍超出已定范围，不因可桥接就自动选用它。
下一步应以固定版本验证：后台命令→模型结束回合→drain→结果入队→模型续跑→最终退出，
同时覆盖失败、超时、取消和任务完成/回合结束同时发生的竞态。

### 隔离端到端验证结果

固定 Pi 0.85.1（当前锁定 nixpkgs 的构建）和 pi-subagents v0.67.0
（commit `910a76278e67dd721dd50b76a241193efdfeb59b`）。
仅在临时目录安装测试依赖，使用最小 exec_background 扩展注册 background-work provider，
没有采用或修改任何正式 exec 包，没有改 Nix 配置或激活部署。

第一组通过真实 Pi CLI 对接本地可控 OpenAI-compatible 服务：服务先要求调用工具，
随后明确结束回合，只有实际收到完成通知才返回确认标记。检查 JSONL 事件与请求内容，
避免将原始工具参数里的标记误当成完成结果。

| 场景 | 实测结果 |
| --- | --- |
| 有 pi-subagents drain，命令成功 | 第一轮结束后仍等待；任务完成通知进入后续模型请求；确认结果后 shutdown(active=false)，exit 0。 |
| 无 pi-subagents drain | 第一轮结束即 shutdown(active=true)，无后续结果处理；子进程管道曾让 PID 短暂存活，但 runtime 已清理。 |
| 命令 exit 7 | 失败状态和输出送达后续模型回合，正常清理；Pi exit 0，表明工具失败并不自动等于 harness 失败。 |
| 实验命令超时并被 SIGKILL | signal/结果送达模型，随后正常清理。此项是测试扩展的命令超时，不是三十分钟 drain 上限测试。 |
| provider.listActiveWork 抛错 | stderr 记录扩展错误，但 shutdown 时仍有活跃工作、无结果续跑，Pi 仍 exit 0。证明 provider 故障不能只靠 CLI 退出码判断。 |

第二组使用真实 LiteLLM 自建 Qwen3.8-27B-4bit：后台执行十二秒命令，
模型调用工具后回答 WAITING 并结束回合；约三秒后命令完成、结果入队；
模型自动再次回答，准确报告输出与 exit 0，最后 shutdown(active=false)、进程 exit 0。
没有使用模型轮询。模型请求延迟使得命令十二秒中一部分发生在第一轮回答之前，
但日志明确证明任务完成晚于第一次 agent_end。

用户随后指定：后续真实模型验证优先使用 `thor/qwen3.8-27b`，暂不回退到
Mac mini 的 oMLX 模型。上一组测试使用的模型 ID 确实是 `Qwen3.8-27B-4bit`，
不能据此称为 Thor 路由实测。provider-fault 是主动注入的扩展故障，不是模型异常。
指定 `thor/qwen3.8-27b` 的补测记录到 HTTP 524（无响应正文），最终达到一百五十秒
外部超时。该次没有启动后台命令，不能将其归因于 drain 故障。

服务恢复后，2026-09-14 改用内网 LiteLLM 入口，显式指定 `thor/qwen3.8-27b`
重试成功：工具启动约 0.4 秒后模型回答 WAITING、触发第一次 agent_end；
此后仍等待约 11.6 秒，十二秒后台命令完成并将结果入队；约 0.94 秒后模型
报告 `THOR_ASYNC_COMPLETE` 和 exit 0，随后 shutdown(active=false)、Pi exit 0。
这次直接验证了 Thor 路由，无需模型轮询。

重试还发现一个独立的上下文预算问题：该服务当前实际总上下文为 4096 tokens，
而 Pi 0.85.1 的 pi-ai `simple-options.js` 固定保留 4096 个安全 tokens，
导致正常计算的可用输出被压到最低 1 token，表现为快速空回复、stopReason=length。
本次仅在临时 provider 的 samplingParams 中显式覆盖 `max_tokens: 512`，
保留真实 contextWindow=4096，并关闭 thinking 后完成短测试。
这会绕过该输出预算限制，不是长会话的通用修复；正式配置仍需处理输入与输出的总预算。
没有修改服务端或部署此临时覆盖。

上游随后将总上下文提升到 262144 tokens，并报告已同步 LiteLLM Terraform。
再次通过内网入口验证：临时 Pi provider 改为 contextWindow=262144、maxTokens=8192，
删除 samplingParams 中的 512-token 强制覆盖，保留 thinking 关闭。
同一十二秒后台任务完整通过：第一次 agent_end 后等待约 11.6 秒，完成通知入队，
模型约 1.5 秒后确认 `THOR_256K_COMPLETE` 和 exit 0，shutdown(active=false)、Pi exit 0。
因此正常输出预算下的 Pi 工具调用与 headless drain 已恢复可用。
本次请求最多使用 547 tokens，不代表重新压测了 256K 满上下文；长上下文容量验证
由服务侧另行记录。当前 agent key 查询 LiteLLM model/info 返回 403，未独立读回在线元数据。
Pi 的自定义 provider 仍需显式配置预算，不会因 Terraform 更新自动同步。

随后将 Thor 加入 Nix 共享模型表，Pi 与 OpenCode 共用 context=262144、output=8192，
标记为支持推理的文本模型；模型标识分别为 `litellm / thor/qwen3.8-27b`
和 `beacoworks/thor/qwen3.8-27b`。共享 LiteLLM provider 默认改走内网入口。
Pi 请求与 HTTP idle 超时、OpenCode provider 请求超时均设为 2400000 ms；
Pi 禁用自动重试，避免长请求重复排队。Pi 设置在 Home Manager 激活时合并指定字段，
保留其他设置并保持文件可写，没有将 settings.json 链接为只读 Nix store 文件。
该部署保留正常 thinking 行为，不沿用容量探针的禁用 thinking 设置。

msi-claw 已完成目标系统构建和 switch（generation 127，沿用原 flake 锁定版本）。
切换前备份并移开了阻止 Home Manager 激活的旧 OpenCode 配置链接，确认 MCP 配置保留。
切换后 Home Manager active、无 failed system units，系统 profile 与运行闭包一致，
Pi/OpenCode 模型列表均包含 Thor；Nix 生成的 Pi provider 实际请求返回 `THOR_NIX_OK`。
异步 exec/drain 扩展仍仅在隔离实验中使用，本次没有将实验原型部署为正式工具。

结论：print 模式的完整成功路径已由真实 CLI 和真实模型验证，
不再只是源码上的可行性推断。这个测试扩展不是生产工具：仅为单任务原型，
未完善进程树取消、日志上限、多个并发任务、reload/会话切换和长期超时恢复。
也未接入 Multica 实跑；正式方案仍需让 provider 故障能明确传递给上层，
并避免把“进程 exit 0”视为所有后台工作已验证完成。

### Claude print 模式的历史对照

后续只读检查了用户提供的 Claude Code 源码归档。归档自述为 2026-03-31
源码快照的非官方镜像，缺少可确认的精确构建版本；未执行该源码，不能以此保证当前版本行为。
该快照的 `src/cli/print.ts` 在处理命令队列后，循环等待仍运行的后台任务，
`LocalShellTask` 也包括在内（排除长期存活的 in-process teammate）。
shell 完成会入队通知，print 循环处理通知并可再次调用模型。
所以“模型回合结束后仍等后台 shell，随后再处理结果”的设计，在该快照中确实存在。

但结果事件与进程结束仍需区分：该快照只为 local agent/workflow 扣留 result，
普通后台 shell 存在时可能先发 result，再继续等待并处理通知。
宿主若收到第一条 result 就销毁进程，仍会破坏后续执行；不是更换 CLI 即可自动解决。

2026-09-14 查询的官方 headless 文档采用不同策略：普通后台 Bash 在 final result
输出且 stdin 关闭后约五秒清理；后台 subagent/workflow 则等待完成，默认连续空闲上限十分钟，
可配置为无限等待。因此不能把旧快照行为推广到所有 `claude -p` 版本和任务类型。
来源：[官方 headless 文档](https://code.claude.com/docs/en/headless#background-tasks-at-exit)。
本次仅为源码与文档核对，没有对当前安装版本进行模型驱动的生命周期实测。

### 用户发现的 pi-background-tasks

用户通过 [Pi 包目录的 task 搜索](https://pi.dev/packages?name=task)
发现 `pi install npm:pi-background-tasks`。这是后台运行扩展，不是 Pi TaskGraph 待办图。
查得 npm 当前版本 2.5.0；本轮仅阅读包元数据和源码，没有安装或执行扩展。

其 `bg_run` 立即返回 ID 和日志路径，默认以 follow-up 消息通知终态并唤醒模型；
用户 `/bg` 默认只通知 UI，不自动启动模型回合。可以查日志、查状态和取消。
这部分与目标很接近，但需要保留以下边界：

- 日志与任务元数据落盘，不等于任务可以跨 Pi 重启继续运行。
  当前源码在正常 shutdown/reload 时停止活跃任务，并抑制此时的完成通知。
- 通知是一次异步投递，未发现可靠的消费确认机制；不能将“已标记 notified”理解为模型已读结果。
- 包同时注册 delegate、Fusion 多模型工作流、attested child 等能力。
  未发现 shell-only 开关；隐藏工具不能去掉这些注册与 hook。
- 默认 manifest 还加载 Anthropic attribution 扩展，会介入相关请求处理。
  单独加载 background-tasks 入口可避开这个独立入口，但仍包含 delegate/Fusion。
- npm 2.5.0 声明的 Pi peer 范围覆盖 0.81–0.84 系列，未覆盖本地 0.85.1；
  这不是已证明不兼容，但不能直接认定兼容。

来源：[包页](https://pi.dev/packages/pi-background-tasks)、
[npm 2.5.0 元数据](https://registry.npmjs.org/pi-background-tasks/2.5.0)、
[注册与关闭逻辑](https://github.com/ismailsaleekh/pi-background-tasks/blob/14aa4ef382952f073bd4d540f57d6e8e3c2789a2/src/extension.ts)、
[通知与任务状态](https://github.com/ismailsaleekh/pi-background-tasks/blob/14aa4ef382952f073bd4d540f57d6e8e3c2789a2/src/core/registry.ts)。

判断：后台 shell 机制值得借鉴，但整包范围超出已确定的 Pi 执行器职责，暂不原样引入。
如果后续能通过上游配置可靠裁剪，再重新比较；不为只用 bg_run 而默认引入另一套多模型编排。

### 两个先前候选的源码复核

| 候选与检查快照 | 机制 | 对当前需求的影响 |
| --- | --- | --- |
| pi-interactive-shell 0.15.2，`eedb89a` | dispatch 后台立即返回，终态可唤醒；PTY、输入和人工接管完整；部分模式支持无 UI。 | 偏交互终端，schema 与原生依赖较大；普通 build/test 必须关闭静默自动退出。 |
| pi-background-work 0.2.0，`e79b0ac` | 用户通过 `/background` 把正在运行的原生 bash 转后台；结果按空闲条件交付。 | 用户手动脱离体验合适，但不是模型可主动调用的后台参数；默认捆绑 subagent fork，需关闭以免重复。 |

`pi-interactive-shell` 的 dispatch 默认 `autoExitOnQuiet=true`，安静超过阈值会真的终止进程，
不是只提醒用户。长时间无输出的编译/测试需要 `handsFree: {autoExitOnQuiet: false}`。
当前源码允许无 UI 的 dispatch+background 或 monitor，但 attach/overlay 需要 TUI。
shutdown 会 killAll，没有跨进程恢复；PTY 使用 zigpty，Nix 平台支持仍待构建验证。
README 在 interactive 是否阻塞、monitor 是否有终态通知两处与该快照源码不一致，
本轮以源码为准。来源：[启动逻辑](https://github.com/nicobailon/pi-interactive-shell/blob/eedb89a9e4618d7416326d9387085a756a2125ee/index.ts)、
[默认配置](https://github.com/nicobailon/pi-interactive-shell/blob/eedb89a9e4618d7416326d9387085a756a2125ee/config.ts)。

`pi-background-work` 保留 bash 参数形状，后台提升由用户命令/快捷键触发；
提升时结束当前模型回合，进程继续。默认 adaptive 策略并非总唤醒，
提升后有新用户输入时可能只通知。reload 可保留工作，退出 Pi 会取消。
其 subagents 可配置关闭，但捆绑依赖仍存在。
来源：[协调器](https://github.com/Davidcreador/pi-background-work/blob/e79b0ac402f435b62ccf11c81e442e306c495e95/packages/extension/src/coordinator.ts)、
[完成投递](https://github.com/Davidcreador/pi-background-work/blob/e79b0ac402f435b62ccf11c81e442e306c495e95/packages/extension/src/completion-delivery.ts)、
[入口](https://github.com/Davidcreador/pi-background-work/blob/e79b0ac402f435b62ccf11c81e442e306c495e95/packages/extension/src/index.ts)。

深入后的结论：暂不锁定上述整包。优先寻找职责更窄的 subprocess 工具，
或只实现启动、结果/日志读取、取消、完成通知这一层；PTY 按实际交互需求增补。
实现前先确认平台如何维持 Pi 会话，以及如何区分等待后台与真正完成。

### 包目录与机器搜索

本次检查到 Pi 目录页面使用 GET `/packages`，参数包括 `name`、`type`、`sort`，
返回服务端渲染 HTML；未确认稳定、公开的 Pi 专用 JSON 搜索 API。
官方文档说明目录收录使用 `pi-package` keyword 的包。
可用 npm registry 搜索 API 取得候选，再检查具体包的版本和仓库；搜索结果不等于兼容性认证。
来源：[Pi package 文档](https://pi.dev/docs/latest/packages)。

本轮已成功调用的 JSON 查询示例：

```sh
curl -fsSL 'https://registry.npmjs.org/-/v1/search?text=keywords%3Api-package%20background&size=10'
```

## edit：先保留默认实现，再做小规模对照

已决定使用 Pi 原生编辑工具，收集真实失败样本后再考虑替换。
工具参数的 JSON 正确，并不等于选对文件和修改位置。
后续比较至少覆盖唯一匹配、重复块、换行与空白、读取后文件变化、多个文件修改。
同时观察错误提示是否能让模型安全地重新读取并重试。

Pi 0.85.1 的参数是 `path` 与 `edits: [{oldText, newText}, ...]`。
同一文件的多处替换对同一原始快照匹配；要求唯一、不能重叠，全部验证后才写入。
先精确匹配，再做有限的 Unicode/空白归一化；不是用语义相似度猜测修改位置。
实现会处理 BOM、换行风格并提供 diff，同文件 mutation queue 减少自身写操作互踩，
但不能据此宣称防住所有外部进程并发修改。
来源：[edit.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/core/tools/edit.ts)、
[edit-diff.ts](https://github.com/earendil-works/pi/blob/v0.85.1/packages/coding-agent/src/core/tools/edit-diff.ts)。

生态主要有两条替代路线：

- Hash/anchor：例如 [pi-hashline-edit](https://github.com/RimuruW/pi-hashline-edit)
  和 [pi-hashline-context-edit](https://github.com/obalado/pi-hashline-context-edit)。
  读取时附行锚点，编辑时引用锚点，减少复制旧文本并帮助发现过时上下文；
  后者还描述了基于读取快照的非重叠三方合并。收益不限于防止弱模型格式错误。
- Patch：[pi-apply-patch](https://github.com/code-yeongyu/pi-apply-patch)
  为 GPT 提供 Codex 风格 freeform 编辑并切换原工具。
  不能据此认定 Qwen 经 LiteLLM 支持相同工具协议，需要单独验证。

本轮不替换默认 edit，也不预先同时暴露多种相似编辑工具。

## todo：可见进度、返回路径与平台分工

待办系统应同时服务模型与人：有稳定 ID、状态、当前任务和未完成项，
用户能随时看，模型在压缩上下文或恢复会话后也能重建状态。
树适合表示目标与子任务；DAG 适合表示多任务共享依赖。
DFS 是遍历或调度策略，不能代替持久化的任务关系。
Pi 的会话分支树也不能直接当作任务依赖图。

暂定从可见、可恢复的任务状态开始。若采用图状任务，还需定义返回父目标的路径、
阻塞原因、完成条件，以及新增支线后如何保留原目标。暂不把全套项目管理系统搬进来。

| 候选 | 已核实能力 | 边界 |
| --- | --- | --- |
| [官方 todo.ts 示例](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/todo.ts) | list/add/toggle/clear 工具；用户 `/todos` 打开列表；从当前分支的工具结果重建状态。 | 扁平待办，不是常驻进度 widget，也不是 DAG；示例需要显式加载。 |
| [Pi TaskGraph / pi-tasks](https://github.com/eleqtrizit/pi-tasks) | JSON 持久化、owner、状态约束、blockedBy/blocks 依赖、footer 实时 widget，提供无阻塞任务批次。 | 是任务图候选；尚未证明完整 DFS 导航体验或图形 DAG 编辑器，也未验证跨会话分支策略。 |

TaskGraph 由用户继续考察，尚未决定安装；若过重，可基于官方 todo 示例补常驻 UI。
“模型没忘但用户看不到”的问题需要 UI 解决，单纯提高上下文长度不能解决。

### 深入依赖后如何返回

用户补充：反复遇到为了 A 做 B、为了 B 做 C，最后模型沿支线继续深入却回不到 A。
图状需求主要针对这个问题。未来运行更大自建模型时，可用上下文可能更紧张，
不能把扩大上下文当作唯一方案。

局部任务关系之外，还需保存当前路径与返回点：根目标及验收条件、当前子任务、
它为什么必要、完成后回到父任务的哪一步。状态在上下文外持久化，
向模型按需提供当前路径；压缩/恢复后如何重新注入仍待实现验证。
不能因为任务文件还在，就假定模型会主动重读。

### 当前工单内部与跨工单的边界

用户进一步提出：若执行中发现依赖规模过大，应由 Multica agent 拆成子需求，
创建工单并指派给相应 dev agent，也可以指派给原身份。
以下是拟定设计，不代表已验证 Multica 现有 API 自动支持这些流程。

| 责任 | Pi / harness | 上层平台 |
| --- | --- | --- |
| 目标 | 记住当前工单范围、完成条件与局部返回点。 | 管理需求、工单之间的关系、负责人和验收状态。 |
| 拆分 | 分解执行步骤；发现超范围依赖时提供拆单建议和证据。 | 接受拆单、创建或复用工单、关联依赖并指派。 |
| 并行 | 用 subagent 做边界明确、结果回到当前会话的子任务。 | 为可独立交付、重试或审核的工作调度独立运行。 |
| 等待 | 保存继续执行需要的检查点，并报告具体阻塞。 | 等待依赖、接收完成事件、重新调度父工单。 |
| 完成 | 提交修改、检查结果和剩余问题。 | 决定工单验收、审核和最终关闭。 |

“由平台负责”不表示必须由另一个模型作出拆单判断。
当前 Pi 中运行的 agent 可以通过平台工具提出或执行已授权的建单操作，
但工单状态与依赖关系由平台保存，不能只存在于 Pi 的本地 todo。

不要只以步骤数、递归深度或经过时间决定拆单。以下情况更适合提升为工单：

- 产生独立交付物或验收条件，超出原工单范围。
- 需要其他负责人、权限、环境、审核或较长的外部等待。
- 需要独立恢复、重试或排期，已经不应绑定当前 Pi 会话的生命周期。

读取一个文件、定位调用链、修复当前变更直接引起的小测试问题，通常仍是局部步骤。
递归越来越深或消耗超出预期是重新评估范围的信号，而非机械拆单阈值。

例如 A 是交付功能，B 是修复一个独立的基础库缺陷：

1. 当前 agent 记录发现与必要性，提交 B 的范围、验收条件及已有调查结果。
2. 平台创建或复用 B，并持久化 A 被 B 阻塞；确认成功后，Pi 才把局部节点标成已移交。
3. A 保存检查点：已完成部分、变更/产物引用、验证结果、等待的工单，以及 B 完成后下一步。
   原始会话全文不是唯一恢复入口。
4. B 可以由另一身份执行，也可以由同一身份的新一次运行执行；无需让 A 的 Pi 进程空等。
5. B 通过约定验收后，平台重新调度 A，提供检查点和 B 的交付引用。
   A 先确认依赖已满足，再继续自己的验收；B 完成不等于 A 完成。

局部 todo 只保留外部工单引用和返回点，不复制 B 的完整内部任务图。
拆单重试需避免重复建单，依赖需要避免环；这是平台操作契约的一部分，
不是再给 Pi 建一个调度系统。失败或取消的子工单也必须让父工单得到明确状态。

因此并不需要先为 Pi 构建通用持久 DAG 调度器。优先验证轻量的局部任务状态、
当前路径与检查点；TaskGraph 只有在改善这些体验时才值得引入。
对于 Paseo 的随手任务，也不默认创建 Multica 工单；超出随手任务范围时再显式移交。

### Multica 后续调查对分工的修正

已取得另一 agent 的源码调查报告，并复核上游 `main` 的 Pi adapter。
报告所检查运行环境使用 Multica 0.4.24，但引用的源码来自上游 `main`，
因此以下不能全部视为该部署版本已验证的行为；实施前需对照实际版本。

- Pi adapter 使用每次 run 新建的 `pi -p --mode json --session <file>` 进程，
  不提供驻留 RPC。会话路径可用于后续运行恢复，但文件必须仍可访问。
  来源：[pi.go](https://github.com/multica-ai/multica/blob/main/server/pkg/agent/pi.go)。
- 调查报告指出，平台通用操作主要通过 task-scoped 环境身份与 `multica` CLI/API 提供。
  `mcp_config` 存在不等于标准 Pi adapter 已消费它；Pi 的设施 MCP 接入仍应独立配置。
  来源：[runtime MCP](https://github.com/multica-ai/multica/blob/main/server/internal/daemon/runtime_mcp.go)。
- 子工单支持 parent/stage：同阶段子工单进入 `done` 或 `cancelled` 后触发父任务通知。
  所以唤醒只说明 barrier 达到终态，不保证依赖成功；父任务必须检查交付结果。
  当前报告未发现任意 `blocked_by` DAG，不应按通用依赖图设计接入。
  来源：[child-done handler](https://github.com/multica-ai/multica/blob/main/server/internal/handler/issue_child_done.go)。
- 报告未发现通用 live-run park API。可行方向仍是持久化检查点后结束 run，
  再由新 run 恢复；不能假设仅有 session 路径即可跨主机或临时 workspace 恢复。

对 exec 的直接影响：未接生命周期协调的后台插件不能原样保证完整运行。
后续已发现扩展层 awaited agent_end drain 的可行路径，因此不再认为必须先改 Multica adapter
或改用 RPC。需验证 provider drain、通知排队和后续回合能在同一次 print invocation 中完成。
对 todo 的影响：先提供用户可见的当前目标、步骤与阻塞原因，
跨运行的检查点与子工单终态处理通过平台接口完成，不在 Pi 内复制平台调度。

## subagent：分层验收

需求分为：创建独立任务；并行执行及完成通知；取消；向运行中的代理追加指令；
主子代理往返消息；持久化与恢复。任意代理网络通信已移出 Pi 的职责。
取消当前生成、给下一安全边界排队一条消息、暂停后续跑，是不同语义。
共享目录和独立 worktree 也不是同一种文件隔离方式。

先让一个主代理可靠管理少量子任务；长期身份、工单与跨会话协作交由上层平台。
验收重点是消息送达时机、取消后的进程清理、任务归属，以及同时修改文件时的行为。

| 候选 | 已核实能力 | 适用范围 |
| --- | --- | --- |
| [pi-subagents](https://github.com/nicobailon/pi-subagents) | 单任务、并行、工作流；前台子 session、后台 runner；完成通知、session/artifacts；FleetView；interrupt/stop/steer/resume。 | 优先评估主子代理管理。已有 child 联系 supervisor 与 parent 回复接口，不必为基本主子通信再装一套插件。 |
| [pi-messenger](https://github.com/nicobailon/pi-messenger) | 曾调查 agent 通信和 Crew 编排能力。 | 已否决：与上层职责重叠，不再作为候选。 |

`pi-subagents` 的 stop 比 interrupt 更强；resume 基于保存 session 创建新 child，
不是恢复同一个操作系统进程。steer/follow_up 的排队位置不同，
投递 receipt 也不表示模型已经遵从消息。
来源：[工具参考](https://github.com/nicobailon/pi-subagents/blob/main/docs/tool-reference.md)、
[supervisor 协作](https://github.com/nicobailon/pi-subagents/blob/main/docs/workflows.md#supervisor-coordination-child-asks-parent)。

Pi 原生没有默认启用这套子代理工具；上述扩展能力不能写成当前 Nix 配置已经具备。
沿 pi-subagents 方向做小规模验证，不引入 messenger；未来通用通信另在平台层考虑。

## web search / fetch：后置选型

用户反馈 Antigravity CLI 的 eligibility check 因账号所在地区不可用而失败，
因此暂时停用共享 `web_search` skill 的分发，保留源码以便恢复。
该 skill 实际包含内置工具、MCP、Codex 和 Gemini CLI 多条路径，
Antigravity 报错本身不能证明独立 Gemini CLI 同样不可用；本次不继续排查账号地域问题。

已使用现有运行时凭据向 Tavily MCP 完成认证与 tools/list，确认提供
`tavily_search` 和 `tavily_extract`，另有 crawl/map/research。
下一步优先评估通过 Pi MCP 适配器仅暴露 search/extract，复用共享服务定义，
不先引入另一个模型 CLI 做搜索中转。当前仅验证认证与工具发现，尚未验证
实际搜索/提取调用，也未将该 MCP 适配器部署到 Pi。

另核实用户已有搜索服务实际为 SearXNG，部署配置启用了 JSON 搜索格式。
2026-09-14 实测 `/search?q=...&format=json`：curl 英文查询返回 HTTP 200、
34 条结果，约 3.45 秒；Python 指定 User-Agent 为 node 的中文查询返回 20 条结果，
约 3.48 秒，结果来自 google cse。Python 默认 User-Agent 的请求返回 403，
而 node/curl User-Agent 均成功，说明接入时仍需验证客户端请求与公网入口的兼容性。
部分引擎降级：DuckDuckGo/Startpage 遇到 CAPTCHA，Brave 遇到限流；
不能将 HTTP 200 解释为全部引擎健康。
该服务可作为已有的搜索后端，接口不要求本次探针提供 API key；
网页全文读取仍单独解决，不能把搜索摘要当作 fetch 结果。
接口参考：[SearXNG Search API](https://docs.searxng.org/dev/search_api.html)。

Pi 默认工具不包含专用联网搜索，生态可以补齐。候选：

- [pi-simple-web-tools](https://github.com/jillesme/pi-simple-web-tools)：范围较小，
  提供 Exa 搜索和网页提取；读取优先使用 HTTP/Markdown、Readability，
  可选 Playwright 回退。适合先验证两个明确工具的方案。
- [pi-web-access](https://github.com/nicobailon/pi-web-access)：支持多种搜索与提取后端，
  包括 Tavily、SearXNG 等，能力与配置面更广。若需要复用特定后端再重点评估。

暂定分别定义搜索结果和网页正文的输出格式，保留来源 URL、截断说明与失败原因。
浏览器交互另议，不默认将 fetch 扩展成完整浏览器自动化。

### pi-web-access 搜索实现复核

包页面显示 0.28.0；本次源码检查 main 为 0.29.0，commit
`192ac1875e3b8f88c78953dbc314949ec9fcaa27`。同时核对发布标签 v0.28.0
（`99bbea065cfd02d2492f42a46dd115c115799938`）：SearXNG 实现与上述 main 相同，
下述基础配置字段在 v0.28.0 已存在。没有安装或部署该扩展。

`web_search` 是统一工具，内部按 provider 分发；SearXNG 路径不经过 MCP，
直接 GET `${searxngBaseUrl}/search?q=...&format=json`，支持时间过滤、域名过滤，
默认取 5 条、最多 20 条，超时 30 秒。结果转换为 title/url/snippet，
answer 字段由现有答案和摘要拼接，不在此 provider 内另调模型总结。
源码：[searxng.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/searxng.ts)。

默认 auto 路由优先已配置的 SearXNG，但会涉及其他 provider 的回退；
交互模式默认 workflow 为 summary-review，另有 curator 界面与摘要模型调用；
headless 默认 none。显式选择 SearXNG 时错误直接返回，不跨后端回退；
auto 才会尝试其他后端，空结果本身不会触发回退。
建议候选基础配置如下，URL 用占位示例，实际由私有 Nix 配置提供：

```json
{
  "searchProvider": "searxng",
  "searxngBaseUrl": "https://search.example.com",
  "workflow": "none",
  "fetchRouting": {
    "providers": ["http"],
    "allowRemoteHostedProviders": false
  }
}
```

这是默认路由与默认工作流，不是强制隔离：工具调用仍可显式覆盖 provider/workflow。
`workflow: none` 避免普通搜索启动 curator/额外摘要；仅设置 autoOpenBrowser=false
不能关闭 curator。本地配置路径应按源码定位：优先 PI_CODING_AGENT_DIR；
有 XDG_CONFIG_HOME 时检查其 pi 目录及旧配置；没有这些环境变量时默认
`~/.pi/agent/web-search.json`。但后续交付发现 npm 0.28.0 的默认路径不同，
实际部署以文末交付记录中的 `~/.pi/web-search.json` 为准。
参考：[index.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/index.ts)、
[utils.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/utils.ts)。

已知缺口：SearXNG provider 不保留 unresponsive_engines，因而本地实测的
CAPTCHA/限流信息可能不会出现在模型结果里；支持 searxngHeaders，但仍应使用
扩展实际请求验证公网入口的 User-Agent 兼容性。搜索端点还受扩展 SSRF/DNS 检查约束。
因此当前方向更新为优先评估该扩展直接复用已有 SearXNG，网页读取先用 HTTP 提取；
Tavily 仍是候选补充，尚未决定启用自动跨后端回退。设施 MCP 接入保持独立议题。

补充核对 v0.28.0：Tavily 搜索为插件内置 HTTP 客户端，直接请求
`https://api.tavily.com/search`，支持 TAVILY_API_KEY 或 tavilyApiKey 凭据来源。
Pi 若采用该搜索路径，不必再向同一模型重复暴露 Tavily MCP；其他 harness 的共享
MCP 配置不因此删除。该实现请求 basic 搜索与 basic answer，includeContent 可请求
raw_content；这不等于实现了独立 Tavily Extract 工具。
源码：[tavily.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/tavily.ts)。

模型可在每次 web_search 调用中设置 provider 为 searxng、tavily 或 gemini 等，
也可传 provider 数组并行查询指定来源；省略时使用配置默认值。
因此可保留 SearXNG 默认，同时让模型按需选 Tavily，而不启用自动回退。

Gemini Web 路径在显式允许浏览器 cookie 访问后读取本机 Google 登录态，
请求 Gemini 网页前端接口，并从回复中提取来源链接；它不是 Google Search JSON API，
也不通过 Antigravity CLI。provider=gemini 先尝试 Gemini API，再尝试可用的 Web 路径，
不能把该值理解为强制仅 Web。此模式依赖本机浏览器登录态与网页协议，
Coder 等临时运行环境不会自动具备这些条件；Antigravity 地区报错也不能证明它可用或不可用。
本次只读源码，未启用或读取浏览器 cookie，未实测 Gemini Web。
源码：[gemini-web.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/gemini-web.ts)、
[gemini-search.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/gemini-search.ts)。

### 搜索路由与多媒体配置讨论

用户接受手动登录，Gemini Web 不因这一点排除；后续验证登录、cookie 解密与续用，
不将 OpenAI 的 Pi OAuth 文件和 Google 浏览器 profile 当作同一种登录状态。
用户明确不接国内搜索后端，包括 Bocha；这是用户的来源偏好，不是本次独立质量评测结论。
配置以明确的非国内 provider 路由为主，不使用 provider=all。

有序默认路由可用 searchRouting.providers 配置；必须同时省略顶层 provider 与
searchProvider，否则显式默认来源覆盖路由。模型单次指定 provider 仍优先。
候选起步配置为以下顺序，尚未部署或确定其他来源的自动加入顺序：

```json
{
  "searchRouting": {
    "providers": ["searxng", "tavily"],
    "fallbackOn": ["unsupported", "transient", "quota", "network", "invalid-response"]
  },
  "workflow": "none"
}
```

不可用来源会跳过；只有列出的错误类型才继续下一来源，空结果不是质量评估回退条件。
useCurrentModel 仅影响 openai 路由项，对符合条件的官方 OpenAI/ChatGPT Codex 模型
使用当前模型的 Hosted Search；它不能让任意 LiteLLM/Qwen 模型拥有搜索能力。
可另外验证 OpenAI 订阅、无 key 的 Exa MCP、显式 Parallel MCP、Gemini Web；
Brave/Kagi/Ollama 等需要另配相应凭据，不为凑齐后端列表而默认启用。
Ollama 此处指托管的 ollama.com/api/web_search 与 web_fetch REST API，
不是本机 Ollama 模型服务，需要 Ollama 账号 API key。
参考：[Ollama Web search](https://docs.ollama.com/capabilities/web-search)、
[路由源码](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/gemini-search.ts)。

网络继续交给 sing-box/上游。本机检查时无 HTTP(S)/ALL_PROXY 环境变量，
已测搜索和文档域名解析到公网地址，因此不启用 ssrf.trustEnvProxy。
该开关只跳过使用环境代理时的本地 DNS 预检，不负责配置传输或解决所有 TUN/fake-IP 情况。
共享网络配置对部分 mesh 域名有 fake-IP 规则；若未来用这些端点，单独验证
SSRF 兼容性，不预先宽泛放行内网地址。

curator 是供用户筛选搜索结果、审核摘要的本地网页，不是 browser-use 自动操作网页。
msi-claw 已有 xdg-open 和 gh，无需为 curator 再补 xdg-utils；当前 PATH 没有
ffmpeg/yt-dlp。默认 workflow=none，保留 /curator、/websearch 可供主动使用。

视频能力仍经 fetch_content：YouTube URL 或本地视频可附 prompt 做内容理解；
timestamp/frames 用于提取指定时间画面，ffmpeg 负责抽帧，YouTube 抽帧另需 yt-dlp。
不装它们仍有依赖 Gemini 等后端的内容理解路径。youtube/video preferredModel
确实进入 API 路径，但设为默认 gemini-3.6-flash 时 Web 路径使用自身默认，
不能据配置字符串断言网页模型已锁定为这一版本。媒体文件送到相应分析后端，
不是由当前主模型必然在本地处理。

配置审查方向：保留 webSearch/fetchContent/getSearchContent；sourceCheck 建议先关闭。
其 assessClaim 使用英文关键词重合和 yes/confirmed/false/not true 等固定字符串
生成 supported/contradicted/confidence，不是独立事实核验模型，也不应当作可靠裁判。
参考：[source-check.ts](https://github.com/nicobailon/pi-web-access/blob/99bbea065cfd02d2492f42a46dd115c115799938/source-check.ts)。
fetch.timeout 单位为秒；
answerProvider/answerModel 仅用于显式 mode=answer，不必为了普通 fetch 固定其他模型，
起步省略该二元组。browserCookies 必须填写实际浏览器/profile，示例 helium/Profile 2
不直接照搬；本机有 Chrome/Firefox，尚未读取 cookie 或确认 Google 登录在哪个 profile。
GitHub clone/PR/issue 特化可保留，需与 gh 登录和下载大小限制一起验证。
图像支持可保留，但 Thor 文本模型不能据此自动获得视觉能力。
PDF 起步可固定 unpdf 做本地文本提取；扫描件/OCR再验证 Gemini/Datalab。
上述仍为待实施配置草案，本轮没有新增依赖、启用 cookie 或安装扩展。

### pi-web-access 首次交付与验证

用户确认按上述方案实施，并保留 GitHub 特化集成，日常使用中再与 CLI 比较。
Nix 固定 npm pi-web-access 0.28.0 tarball、依赖 lock 与 npmDepsHash，
Pi 0.85.1 的 jiti aliases 提供 Pi peer API；未重复安装另一套 Pi。
配置采用 SearXNG → Tavily 的有序默认路由、workflow=none、sourceCheck=false、
HTTP 正文提取、PDF unpdf；保留三个基本工具及四个命令、图像/视频/GitHub 能力。
Gemini 作为可显式选择的来源，没有加入默认自动回退链。

用户确认接受 Chrome 专用于 agent Google 登录，Firefox 继续日常使用。
已选择 Chrome Default 并允许 cookie 读取；Linux 加入 libsecret 的 secret-tool。
未新增 ffmpeg/yt-dlp，指定时间抽帧仍需这些依赖。未修改默认浏览器。

交付纠正：npm 0.28.0 的 utils.ts 与 Git 标签 v0.28.0 在默认配置目录上不一致，
前者默认 `~/.pi/web-search.json`，后者为 `~/.pi/agent/web-search.json`。
隔离测试使用 PI_CODING_AGENT_DIR，未暴露此差异；正式环境的 /google-account
诊断发现后已修正 Nix 激活路径，旧误放文件已备份。关键 provider 文件
gemini-search/searxng/gemini-web/gemini-web-config/tavily 与所审标签一致。
web-search.json 保持可写，凭据通过运行时命令读取，不写入 Nix store。

msi-claw 最终切换至 generation 130，Home Manager active、无 failed system units，
系统 profile 与运行闭包一致。目标构建、flake 全量展示、激活脚本语法与 diff 检查通过。
真实 Pi CLI 配合受控模型响应发起真实网络调用：SearXNG 返回 2 条结果，
Tavily 返回 2 条结果，HTTP fetch 返回文档正文，全部 isError=false。
额外 Gemini 查询也成功返回官方文档链接；测试配置没有 Gemini API/ADC/Cloudflare
凭据，走浏览器 cookie Web 路径。Chrome 登录态诊断 available=true，未输出 cookie。
上述证明接口可用，不构成搜索质量或事实正确率评测。
Thor 模型自主调用的补测在工具启动前等待，已取消；不把受控模型测试称为 Thor 端到端通过。

## MCP：优先复用适配器

另评估 [pi-provider-litellm](https://pi.dev/packages/pi-provider-litellm)（页面版本 2.3.0）。
其主要增量是代理模型自动发现、登录/SSO、多 provider 别名与 LiteLLM 网关侧 MCP/Skills。
目前建议继续本地 Nix provider：Pi 和 OpenCode 共用模型表，预算与模态显式维护，
凭据已有运行时读取，暂不需要再引入登录或网关工具管理层。
自动发现优先 /model/info，但当前 agent key 对该接口曾返回 403，降级到 /v1/models
未必取得可信的上下文/输出预算，不能直接视为解决元数据同步。
该包默认启用 LiteLLM MCP/Skills 集成；若未来采用，需按现有架构明确关闭或启用，
并替换原有同名 litellm 注册，避免两个扩展争用。模型频繁增减或引入 SSO 后再重评。
这是基于包说明与本地配置的选型建议，未安装或端到端验证该包。

Pi 核心没有内建 MCP 客户端；上游将其作为扩展方向。
候选 [pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter)
支持 stdio、Streamable HTTP/SSE、Bearer/OAuth，以及代理式或直接工具暴露。
其文档也提供按搜索结果激活直接工具的模式；这些是上游功能说明，尚未本地验证。

暂定先接一个已有服务，验证发现、调用、超时、取消和认证刷新。
工具少时优先直接暴露清晰 schema；工具多时再比较按需发现的额外调用成本。
不默认把所有设施的全部工具塞进上下文。
连接配置由 Nix 管理，凭据运行时读取，OAuth 状态保持可写。
验收应使用实际服务要求的传输和认证方式，不能仅凭“支持 MCP”认定兼容。

已检查现有配置：服务源在 `programs.mcp.servers`，OpenCode 通过
`programs.opencode.enableMcpIntegration` 消费该共享定义。
Pi 应复用这一源，生成适配器需要的配置，而不是再维护服务清单。
服务同时包含本地 stdio 命令和远程 HTTP/headers；实施时需转换环境变量占位符，
并验证宿主进程实际继承的环境。这里的选项是 OpenCode 集成入口，不能直接给 Pi 打开同名开关。

## 下一步与待验证项

建议顺序（待后续讨论调整）：exec 完成通知 → 可见 todo → MCP 最小接入 →
subagent 基础生命周期 → web search/fetch。edit 保持默认，在这些实际任务中收集对照样本。
架构边界与 edit 选择已确定；pi-subagents、MCP 的方向已明确，版本与部署仍待实施。

| 能力 | 最小验收场景 |
| --- | --- |
| exec | 启动长命令后继续回答；停止输出等待；命令完成后收到一次通知；失败、超时和取消均有可查结果。 |
| edit | 重复块拒绝歧义修改；文件变化能被发现；常见换行差异可处理；修改结果可检查。 |
| todo | A→B→C 在 C 阶段压缩后能回到 B、A；大型依赖移交工单后，父任务可从检查点恢复；分支行为明确。 |
| subagent | 两个独立任务并行；取消其一；对另一个追加指令；最终结果归位且不重复通知。 |
| MCP | 一个实际服务完成认证、发现和调用；失败可诊断；取消和重连有明确结果。 |
| web | 搜索与正文读取分别验证；结果保留来源；大输出可按需读取。 |

配置查漏补缺留待上述机制确定后，重点复查模型工具调用模板、
上下文预算与压缩、扩展版本锁定、状态目录可写性，以及 Linux/macOS 行为差异。
