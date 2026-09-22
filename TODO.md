[中文](TODO.md) | [English](TODO_en.md)

# TODO

## 文档 i18n 同步检查

- [x] 采纳 markdown 命名约定：`{NAME}.md` 为权威来源，使用中文书写；
  翻译为 `{NAME}_{VARIETY}.md`（首个语言变体：`en`）。`NAME` 不得包含下划线。
- [x] 实现 `utils/check-docs-i18n.py`（+ `utils/test-check-docs-i18n.py`）：
  在提交范围内，含多个成员的文档族必须整体变更；单成员族通过，即文档族在
  首个翻译落地时加入检查。可在 PR 正文中以 `doc-i18n-skip: <NAME>` 行按族豁免。
- [x] 按 `check-secrets.yaml` 的模式，在 push + pull_request 上添加
  `.forgejo/workflows/check-docs-i18n.yaml`。
- [ ] 在 `main` 的 Forgejo 分支保护中将 `Check Docs i18n` 标记为必需状态。
- [x] 迁移仓库入口：`README.md` 成为中文版，新增 `README_en.md`，
  两者均带语言切换头部链接。
- [x] 迁移 `AGENTS.md` 与 `TODO.md` 本身：中文为权威来源，新增
  `AGENTS_en.md` / `TODO_en.md` 翻译，均带语言切换头部链接。
- [ ] 迁移 `docs/deploy-nix-darwin.md` 时，修复其中过时的
  `scripts/deploy-nix-darwin.sh` 引用（脚本实际位于 `utils/`）。

## Multica 上游

- [ ] 准备并向上游提交 durable-webhook 的 Issue 去重修复。
  - 将 [`multica-webhook-issue-dedup.patch`](docs/ci-cd/patches/multica-webhook-issue-dedup.patch)
    变基到 Multica 当前默认分支。
  - 重新运行聚焦的 PostgreSQL 后端回归测试。
  - 编写面向上游的 issue 或 PR 描述，不带 Beacon 部署细节或凭据。
  - 跟进上游评审，并用官方修复版本替换临时的下游构建。

- [x] 为 durable-webhook 去重修复构建并验证临时的打过补丁的 Multica 后端镜像。
  - 2026-09-16 的生产冒烟测试确认：两条不同投递创建两个 Issue，而同一条
    投递的重试保持幂等。
  - 可复现的 `multica-backend-oci` flake 输出与 Forgejo 发布 job 使用
    `0.4.24-beacon.1`，直到官方修复版本替换它。

## Automation 入口

- [ ] 将 Forgejo、n8n 与 Multica 的机器间 webhook 迁移到自托管入口或
  私有服务发现。
  - 迁移完成前，保留公开的 Cloudflare 路径作为兼容层。
  - 保留范围受限、一次性的回调权限与固定的目标允许列表；私有路由不得
    替代应用层授权。
  - 只有在 agent 不再经过 Cloudflare、且私有路径具备同等可观测性与
    可用性之后，才移除回调专用的 User-Agent 变通措施。

## Renovate 评审续期

- [ ] 为 Renovate 评审返回 `human_required` 后添加一等续期路径。
  - 签名评审权限是一次性的，且已被 `human_required` 回调消费，因此之后
    的人工批准目前无法对同一 PR head 提交 `approve`。
  - 在允许列表内的人工批准了被评审的确切 SHA 后，签发新的短期权限，
    绑定同一仓库、PR、head SHA、评审证据与 Multica Issue，而不是
    重放已消费的权限。
  - 在续期时重新读取 Forgejo 与人工批准，拒绝过期或已变更的 head，并保留
    现有的合并队列与分支保护检查。
  - 为 approve、reject、过期、重放、并发 head 变更与重复人工批准事件
    添加回归覆盖。
  - 实现之前，以签名空提交刷新 PR 仅是被审计的 fail-closed 变通措施，
    且仅在其 Git tree 被证明相同时使用；它不是预期的稳态工作流。

## Agent 验证工具

- [ ] 为 agent 请求的验证原型化有界的 n8n MCP 工具。
  - 复用现有的 Forgejo 验证实现；不要创建语义不同的第二套测试命令。
  - 从精确 SHA 的 Nix 求值与 Helm 渲染工具开始。
  - 允许列表限制仓库与目标，凭据保留在 n8n/runner 内，返回结构化结果与
    不可变的证据 URL。
  - 测试授权、恶意输入、重放、超时、取消、容量不可用以及结果到 SHA 的绑定。
  - 将 MCP 验证与审批及合并权限分开。

## GitOps 验证迁移

- [ ] 用 `flate` 验证替换已停用的 `flux-local` workflow。
  - 在更改必需状态名称之前，保留当前的测试与渲染 diff 覆盖。
  - 以不可变摘要固定可执行文件或容器，并测试 Forgejo Actions 兼容性。
  - 单独评估 `konflate` 作为只读的 Forgejo PR 评审服务；不要使新服务
    成为初始 CLI 迁移的前置条件。
  - `flux-local` 8.4.0 仅保留为短期兼容桥。

## Wanxiang 集群升级

- [x] 完成 [`wanxiang/docs/cluster-upgrade.md`](wanxiang/docs/cluster-upgrade.md)
  中描述的 Talos 1.13.10 / Kubernetes 1.36 阶段，包括 Cilium、CloudNativePG
  与 Longhorn 前置条件、1.36.3 小版本过渡，以及独立的 1.36.4 补丁更新。
- [ ] 在 1.36 稳定观察期后，将 Talos/Kubernetes 1.37 阶段作为一次独立的
  受评审滚动进行准备。
  - 在 Stage 3 客户端/控制面顺序决定之前，保持 Renovate PR #36（kubectl 1.37）
    与 PR #37（talosctl 1.14）开放。
  - 将已完成的 Kubernetes 1.36.4 补丁与 1.37 小版本过渡分开，并保留其
    独立的滚动证据。
  - 在批准前，针对每个目标 Kubernetes 小版本，重新评估开放的 Flux、Cilium、
    CoreDNS、Envoy Gateway 及相关 chart PR。
