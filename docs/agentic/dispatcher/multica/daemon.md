# Multica 服务与 daemon

Multica 管理长期 Agent 身份、工单、Autopilot 和任务运行；Coder 提供实际执行的工作区。它们是两层系统，不应把万象中的 Multica Web 服务误认为执行 agent 的机器。

## 万象服务

`wanxiang/kubernetes/apps/development/multica/` 使用 `0.4.24` Helm chart，后端镜像为带 webhook Issue 去重补丁的 `0.4.24-beacon.1`，前后端各一副本，数据库为外部 PostgreSQL。配置关闭公开注册和用户自行创建工作区，启用 VCS 集成；入口为集群 Gateway 的 HTTPS 路由。补丁与 Renovate 审查流程另见 [Multica 合并门禁](../../workflow/infra-ops/renovate-multica-gate.md)。这些是仓库声明，不代表此刻 Pod 健康状态。

## 执行 daemon

Coder 的 `coding-agent` 模板位于 `wanxiang/kubernetes/apps/development/coder/templates/coding-agent/main.tf`。每个工作区有持久化的 `/home/coder` 卷，工作目录为 `/home/coder/workspace`；工作区镜像含 `multica` CLI `0.4.24` 和 Pi 等 agent 工具。Coder agent 的启动脚本在 CLI 可用时执行 `multica daemon start`，失败时查询 `multica daemon status`。因此 daemon 依附 Coder 工作区生命周期，不是 Multica HelmRelease 里另一个常驻执行器。

工作区启动时挂载运行所需凭据、Git SSH 和模型入口；具体授权由 Secret 与工作区模板控制，不在本文复制凭据内容。执行中的 agent 应先确认当前工单、运行 ID 和目录，再对代码或其他资源操作；不能因为同一工作区里有未提交改动，就推断它们属于自己的任务。

2026-09 的 [Pi 接入记录](../../harness/research.md#coder-与-multica-部署2026-09-14)确认过 Multica → Pi → LiteLLM → Thor 的一次工具调用链路；这是当时的一次验收，不保证所有模型或当前工作区均在线。Daemon 的任务内身份和 CLI 细节见 [任务执行](task-exec-flow.md)。
