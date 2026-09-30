# Paseo 与 Multica 的 Forgejo 集成

两个消费方都要读取 Forgejo 上的 PR：`Paseo`（Copilot 调度层）用于个人工作区的 PR/CI 面板，`Multica`（Autopilot 工单）用于把工单与 PR 关联。二者机制不同，缺口也各自独立。本文记录机制、现状和补齐步骤；部署声明不代表此刻可用。

## Multica（已接通，含一次历史修复）

上游 `multica-ai/multica` 用 VCS 集成读取自托管 Git 提供方：`server/internal/integrations/vcs/forgejo.go` 注册了 `forgejo` 与 `gitea`（wire-identical），`vcs.go` 说明这是 token-based provider，**只从 webhook 镜像 PR 与 commit status，不轮询、不回填历史**。GitHub 仍走单独的 App handler。

### 当前状态（2026-09-30 核实）

- 工作区已有一条 connection：`aa9af3ad-9b11-449e-8a91-c1e15af45c97`，provider `forgejo`，`instance_url=https://forgejo.beaco.works`，`account_login=multica`，workspace `143a067c-ff0d-420a-8c6a-497c4786c747`。
- webhook 路径为 `/api/webhooks/vcs/<connectionId>`；两个仓库的 hook 均已存在：`infra-private`（id 3，原有）与 `infra`（id 6，本次补上），共用同一 connection 的一次性 secret（已轮换并同步）。
- 镜像表 `vcs_pull_request` 中的 75 行全部来自 `infra-private`，印证 `infra` 侧此前从未投递。

### 本次修复的两个问题

1. **`infrastructure/infra` 没有 Multica webhook**：只有 n8n 的 automaton hook，导致 `infra` 的 PR 从未被镜像。已在 `infra` 上创建同一 connection 的 Gitea 类型 hook。
2. **数据库 schema 领先于运行镜像（版本偏斜）**：Multica 的 `schema_migrations` 已应用到 `490_drop_triage_status_key_reservation`（含 `468_drop_reference_only_column`，于 2026-09-16 应用），即 `reference_only` 列是被后续迁移**主动删除**的；而运行中的后端镜像 `0.4.24-beacon.1` 的代码仍在查询该列，于是 `GET /api/issues/{id}/pull-requests` 返回 500——这才是「无法加载对应 Forgejo PR」的直接原因。临时把该列加回（`ADD COLUMN IF NOT EXISTS ... DEFAULT FALSE`）让旧镜像恢复 200；**真正的修复是把后端镜像升级到与库结构匹配的版本**（见下方升级计划，`468` 之后代码不再使用该列）。

### 链接规则

Multica 只按 PR 的 **标题前缀 / 分支名 / 正文 closing 关键字**（`Closes|Fixes|Resolves <ID>`）自动建立链接；仅在正文裸提及会写成 `reference_only`，在 issue 的 PR 列表里隐藏。**没有手工 link API**，升级到上游 `main` 也没有。因此让 PR 显示在 issue 上，只能让 PR 内容带上 issue 标识。

### n8n 回写（本次新增）

Renovate 拥有 PR 的标题/正文/分支，且 Multica 的 issue 标识是**异步生成**的（派发响应只有 `autopilot_id`/`run_id`），所以原流程永远无法让审核 issue 显示其 PR。

在 **Multica 审查回调** 路径中，capability 验证且当前 PR 校验通过后，n8n 依次：

1. 按 JTI 查 `multica_review_dispatches` 取 `autopilot_id`/`run_id`；
2. `GET /api/autopilots/{id}/runs/{run_id}` 取 `issue_id`；
3. `GET /api/issues/{issue_id}` 取 `identifier`；
4. `PATCH /api/v1/repos/{repo}/pulls/{n}`，在 PR 正文追加 `Closes <IDENTIFIER>`（幂等：标题/正文/分支已含该标识则跳过；best-effort，不阻塞门禁）；
5. 继续原有的 `Set Multica Review Status`。

新增节点：`Get Dispatch For Link`、`Get Run For Link`、`Get Issue For Link`、`Compose Linked PR Body`、`Link Needed?`、`Edit Renovate PR Body`、`Emit Review For Status`；回归测试在 `utils/test-n8n-infra-ci.mjs`。

安全性：Forgejo 的 `edited` 事件不会触发 Renovate 复核（派发只认 `opened`/`synchronize`/`reopened`），状态表按 head SHA 去重，因此 n8n 自改 PR 不会形成循环；写回使用 `FORGEJO_GATE_TOKEN`（`write:repository`），不引入新凭据。

### 已知限制

- commit status 未镜像（`vcs_commit_status` 为 0）：当前 hook 未订阅 commit-status 事件，Multica 期待的 `status` 事件不会到达。
- 历史 PR 不回填；已有 issue 需等 PR 下一次事件（或一次性回填）才有链接。
- Renovate 下次更新会重写正文、抹掉追加行；但每个 head SHA 都新建 issue 并在回调时重写，最新一轮仍有链接。

## Paseo（暂缓）

Paseo `v0.9.2` 原生列出 `forgejo`、`gitea` 与 `codeberg`（`packages/protocol/src/forge-manifest.ts`、`packages/app/src/git/forges/`），但 Gitea 家族在服务端全部经 `tea` CLI 实现（`packages/server/src/services/gitea-service.ts`）。当前 `msi-claw` daemon 无法读取 Forgejo PR：

1. daemon 的 PATH 没有 `tea`：`resolveTeaPath → findExecutable("tea")` 返回空即判定不可用。
2. `tea` 现有登录只属于 `forgejo.beaco.works`，而项目 remote host 是 `forgejo.tail5d550.ts.net`，`probeGiteaHost` 的 host 匹配不上。
3. 现有 `tea` OAuth 登录的 refresh token 已失效（`token was already used`），需重新登录或改用 PAT。
4. 另有一条独立问题：daemon 的 `git fetch` 报 `Permission denied (publickey)`，systemd 服务没有 SSH agent。

上游在 `gitea-service.ts` 自注 Forgejo 软件探测「未在真实自建实例验证」。补齐方案与验证项待 [Paseo TODO](paseo/TODO.md) 展开；本文暂不实施。

## Multica 升级计划

目标版本：**v0.6.0**（2026-09-28，最新；服务端迁移到 `563`）。库已到 `490`，升级会应用 `491..563`；这也顺带消除版本偏斜——后端代码与库结构对齐后不再使用 `reference_only`，升级后可 `DROP COLUMN` 恢复与上游一致。

影响面：

- `packages/multica-backend/default.nix`：`version`（如 `0.6.0-beacon.1`）、`rev = v0.6.0`、`fetchFromGitHub.hash`、`vendorHash`；下游补丁 `multica-webhook-issue-dedup.patch` 需重切。
- `wanxiang/kubernetes/apps/development/multica/app/ocirepository.yaml`：chart `tag: 0.6.0`。
- 同目录 `helmrelease.yaml`：后端镜像 tag `0.6.0-beacon.1`（前端与 chart appVersion 跟随，无需改）。
- `hosts/agents/coding/home.nix`：`multica` CLI 升到 `0.6.0` 并更新 hash（release 资产 `multica-cli-0.6.0-linux-amd64.tar.gz` 存在）。

已核实的上游差异：

- 迁移：v0.6.0 含 `442`/`462`/`468`，最大 `563`。库已过 `468`，升级不会重跑它；临时补的列不会被自动删除，需升级后手动 drop。
- 去重补丁：v0.6.0 的 `dispatchCreateIssue` **仍**无条件调用 `LockAndFindRecentAutopilotDuplicate`（标题级 recent-duplicate guard），而 `AdmitAutopilotWebhookDelivery`/`webhook_delivery_id` 已存在。因此下游补丁仍需保留，但 v0.6.0 的 `dispatchCreateIssue` 已带 `run` 形参，需按其新上下文重切。
- Chart：v0.6.0 的 values 键与我们使用的集合一致，且仍**不**暴露 `MULTICA_PUBLIC_URL`（`webhook_url` 回退到 UI origin，行为不变）。

切换顺序与风险：

1. 更新 `packages/multica-backend` 并构建/推送镜像，确认注册表可匿名拉取；
2. 更新 chart tag 与镜像 tag，让 Flux 协调；
3. 观察 `migrate up`（`491..563`）完成、Pod 健康；
4. 升级后 `DROP COLUMN reference_only`（旧代码已不在），再验证 `pull-requests` 与链接；
5. 风险：从 `0.4.24` 跨约 40 个版本，需核对 chart values、VCS/daemon 协议与凭据加密 key 不变；`0.4.24-beacon.1` 上的 webhook 去重补丁行为必须在新版本重验（`utils/test-*` 与线上冒烟）。

## Terraform 评估结论：不采用

社区 n8n Terraform provider 均不成熟（≤19★、覆盖不全）；工作流本体是图 JSON，用 TF 只会把 `nodes`/`connections` 塞进 HCL 大字符串，diff 更差且与现有 canonical JSON 测试冲突；还会为 k8s 侧引入第二套状态（仓库其余部分统一用 Flux/Comin）。维持「JSON 源 + ConfigMap + Stakater Reloader + CI 校验」，用 n8n MCP 做编写/校验/测试，不用 TF 接管。

## 待核实

- Multica 是否有受支持的 commit-status webhook 事件可订阅。
- 升级目标版本与 chart values 差异。
- `tea` 版本对 `tea api -i /api/forgejo/v1/version` 的支持（影响 Paseo 的 Forgejo 探测）。
