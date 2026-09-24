# Agent 任务派发

能交给 Agent 的长期任务优先使用 Multica 工单和 Autopilot，简单的 Nix 包更新也尽量减少个人记忆负担。集中记录任务、运行位置和分支，避免做到一半却找不到工作现场。即使只是临时实验，若需要持久的目录和交接，也优先使用 Coder 工作区。个人设备上的随手协作由 Paseo 承接；超出会话范围时再明确移交 Multica。

## 目录
- [Multica 服务与 daemon](multica/daemon.md)：万象服务、Coder 工作区及运行身份。
- [Multica 任务执行](multica/task-exec-flow.md)：工单、运行、工作区与 CLI 的边界。
- [Paseo daemon](paseo/daemon.md)：个人设备、Coder 镜像和跟随上游的版本策略。
- [Paseo relay](paseo/relay.md)：自建转发与 Tailnet 直连的区别。
- [Paseo 待核实项](paseo/TODO.md)：语音、访问控制、配对与升级验证。
- [AstrBot → Multica 中继](astrbot/README.md)：Issue 入口的权限边界与执行沙箱。

Forgejo、n8n 与 Multica 的具体 CI/CD 门禁见 [infra-ops](../workflow/infra-ops/README.md)。
