# Pi 的职责与配置取向

2026-09-13 至 14 日的本机 Codex 会话讨论了 Pi harness 的边界。目标是让 Pi 承担模型和基本工具的执行，不在 Pi 内再造一套任务平台。

- 长程任务、工单、长期 Agent 身份和交接由 Multica 管理；Coder workspace 承载执行环境。
- 个人设备上的临时任务由 Paseo 选择设备、harness 和模型。
- 未来的 IM Agent 也尽量由上层平台管理身份和消息入口，不把部署位置或聊天平台绑定进 Pi 配置。因此暂不引入 `pi-messenger`。

工具取向：编辑先使用 Pi 默认实现；基本子代理沿 `pi-subagents` 方向评估；todo 主要让人看到当前安排，跨会话计划和拆分仍交给 Multica；搜索、抓取和 MCP 按实际需求接入，不因服务已部署就认定模型可调用。exec 的交互语义单列在 [exec.md](exec.md)。

这些是架构选择，不表示每项工具均已启用。具体配置与试用记录见 [Pi harness 调查与试用记录](research.md)；模型响应被截断或手动中断后的历史重放见 [turn-replay.md](turn-replay.md)。

## 实现边界

通用实现位于公开仓的 [Pi Home Manager 模块](../../../modules/home/pi.nix)：包括异步 exec、中断标记、web-access 打包和运行时设置。模型 API 地址、密钥及 Tavily 密钥从运行环境或私有仓的 SOPS 解密文件读取，不写入公开仓或 Nix store。搜索端点和模型清单可公开审查，但私有主机拓扑、浏览器 Cookie 权限和工作区部署仍由私有配置决定。

目前 private flake 锁定的是此前的公开仓修订；公开模块在审查、提交并更新该输入前，不替换私有仓正在使用的 Pi 实现。
