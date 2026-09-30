# Forgejo 服务账号

自动化使用相互独立、权限受限的 Forgejo 账号，避免依赖发现、策略判断和合并操作共用凭据。

| 用户名 | 邮箱 | 用途 | 仓库权限 |
| --- | --- | --- | --- |
| `renovate` | `renovate@noreply.forgejo.beaco.works` | 发现依赖更新并创建 PR | `infrastructure/infra` 和 `infrastructure/infra-private` 的写入协作者 |
| `multica-gate` | `multica-gate.no-reply@beacoworks.xyz` | 读取 PR，写入 `policy/merge-gate` 或 `policy/prod-merge-gate` 提交状态 | 两个基础设施仓库的写入协作者 |
| `multica-merger` | `multica-merger.no-reply@beacoworks.xyz` | 满足受保护分支要求后合并 PR | 两个基础设施仓库的写入协作者 |
| `multica-gitops` | `multica-gitops.no-reply@beacoworks.xyz` | GitOps + 运维主 Agent 编码、推送分支和创建 PR | 两个基础设施仓库的写入协作者；无合并白名单权限 |
| `multica-nix-packager` | `multica-nix-packager.no-reply@beacoworks.xyz` | Nix 打包维护者编码、推送自有 fork 和创建 PR | `infrastructure/infra` 可读协作者；仅自有 fork 可写；无合并白名单权限 |
| `ci-publisher` | `ci-publisher.no-reply@beacoworks.xyz` | 发布可丢弃的 OCI 冒烟测试镜像 | 不属于仓库或组织；只拥有 `ci-publisher/` 下的软件包 |

`multica-gate` 不能通过自动化流程合并 PR。其 PAT 只有 `write:repository` 和 `read:issue` 权限，保存在加密的 n8n SOPS Secret 中。`read:issue` 用于重新读取与 SHA 绑定的作者确认评论；不能仅信任 webhook 内容。Multica Agent 只获得向 n8n 提交审查结果的凭据，不持有 Forgejo PAT。

`multica-merger` 的 `write:repository` PAT 作为独立的 n8n 凭据 `Forgejo Multica Merger Token` 保存，仅供固定的 Forgejo 合并请求节点使用；它不会通过环境变量暴露，也不会提供给 Renovate、Multica Agent 或普通审查节点。

`ci-publisher` 只有 `write:package` PAT，以 `CI_REGISTRY_USER` 和 `CI_REGISTRY_TOKEN` 保存在 Forgejo Actions 中。该账号刻意不加入 `infrastructure` 组织，使分支 CI 能覆盖其临时软件包，却不能发布生产镜像或修改仓库。

## 受保护分支

Forgejo 对 `infrastructure/infra` 和 `infrastructure/infra-private` 的 `main` 分支实施以下保护：

- 禁止直接推送，包括管理员；
- `policy/merge-gate` 和 `Check Secrets / check-secrets (pull_request)` 都必须通过；
- 被拒绝的审查和落后于目标分支的 PR 会阻止合并；
- 仅允许 `multica-merger` 执行合并。

合并白名单和合并账号凭据已经启用。n8n 只有在验证与 SHA 绑定的审查凭证后才能安排合并；Forgejo 仍负责执行全部分支保护要求。目前这些规则通过 Forgejo API 管理，并在此记录，尚未由仓库声明式管理。

`infra-private/prod` 的保护规则应单独要求 `policy/prod-merge-gate`，不得复用 `main` 的 `policy/merge-gate`。设置该规则前，必须先发布并验证支持 `/approve-prod <完整头部 SHA>` 的 n8n 工作流。

本文不得写入密码、PAT、webhook URL 或回调凭据；其真实来源是对应的 SOPS Secret 或 Forgejo 凭据库。

## [WIP] 各 Agent 独立的开发身份

GitOps + 运维主 Agent 已以 `multica-gitops` 作为首个独立编码身份。其专用 Coder 工作区从 SOPS Secret 获取 SSH 推送密钥、GPG 提交签名密钥与 Forgejo API 令牌；提交邮箱为 `multica-gitops.no-reply@beacoworks.xyz`。签名密钥与 SSH 推送密钥分开，GPG 公钥已在 Forgejo 验证。其他 Agent 的身份隔离仍需逐项完成。

GPG 指纹为 `B2FAAFEAC5E4727FB4AF35784932794C9ED791BE`，SSH 推送密钥指纹为 `SHA256:sH+YsSs8xbe3YNlzjsc0ZMhu1RBO977sSWv6JnARkhc`。Multica daemon 的专用 PAT 只用于工作区首次配置；持久 home 中保留其自动续期结果，启动脚本不会覆盖它。

Nix 打包维护者的 Forgejo 账号为 `multica-nix-packager`，GPG 指纹为 `8F57D2F99F73669B937CC52E93BF0D5DA19E76C2`，SSH 推送密钥指纹为 `SHA256:hhj50kXhTq/2Q03jqu4wjHe+OqKRN4+F8/s03sYTrPY`。其独立工作区只挂载专用 Agent 和 Git SSH Secret，不挂载 kubeconfig、Talos 配置或 SOPS age 密钥。该账号的 Forgejo PAT 仅有 `write:repository` scope；上游仓库权限为可读，自有 fork 可写。

Homelab 巡检（只读巡检 Autopilot）计划从共享的 `nixos-agent-coder` 工作区迁往专用 `homelab-inspection-agent` 工作区，避免与外部模型顾问 Agent 共用容器和凭据。该工作区只挂载独立的 Agent harness Secret，不挂载 Git SSH 或通用 infra Secret，也不注入 Forgejo 令牌。巡检所需的跨基础设施只读访问需另行按资源授权并验证；新工作区和 Multica runtime 绑定完成前，不能称为已迁移。

启用顺序：先为新 daemon 提供独立的 Multica 凭据并确认模板已发布；创建工作区后验证 Git SSH、infra Secret、Forgejo 凭据均不可用，再将巡检 Agent 绑定到新 runtime。只读巡检接口尚未接入的系统应在报告中列为无法检查；现有 OpenStatus 状态页和公开 inventory 可作为首批低权限信息源。旧工作区的持久化 HOME 仍需单独清理，避免后续顾问 Agent 继续接触旧凭据。

Coder `coding-agent` 模板为 `gitops-agent`、`nix-packager-agent`、`homelab-inspection-agent`、人类空间 `infra-maintainer` 和仍供其他 Agent 使用的旧 `nixos-agent-coder` 工作区映射凭据；其他新工作区默认不挂载 Agent、Git SSH 或基础设施 Secret。

每个 Agent 配置至少应隔离：

- Nix 配置、substituter、受信任密钥、构建机和缓存；
- Git 作者名、免回复邮箱、签名策略和凭据助手；
- 需要写入仓库时使用的专用 Forgejo 账号和最小权限 PAT；
- 仓库允许列表，以及读取、推送分支、创建 PR、审查 PR 等操作权限；
- 缓存、home 和临时目录，避免全局 `gitconfig`、Nix 状态或凭据在 Agent 之间泄漏。

确定后的账号名和免回复邮箱应记录在本文；令牌与私有签名材料仍保留在相应的秘密存储中。Agent 身份不能复用 `renovate`、`multica-gate` 或 `multica-merger`，因为它们分别负责依赖发现、策略判断和合并。

`CODEOWNERS` 用于请求路径所有者审查。普通编码 Agent 只获得自己 fork 的写权限；`policy/merge-gate` 在接受人工精确 SHA 审核后核对 PR 作者、来源 fork 和相对 merge base 的完整文件变更。`multica-nix-packager` 只可从 `multica-nix-packager/infra` 提交、且只修改公开仓 `packages/` 的 PR；其他普通作者默认拒绝。`beacon1096` 和 GitOps 主 Agent `multica-gitops` 可跨 Agent 范围修改。该规则只限制进入基础设施仓库 `main` 的 PR，不限制 Agent 在自己 fork 上推送。此前仅适用于 Clerk 的规则已移除。

在独立身份建立前，经明确授权的 Agent 可以使用 `beacon1096` 身份。Forgejo 和合并门禁必然将其视为与人类操作员相同的主体。由这一共享身份创建的 PR 无法在 Forgejo 中自我审查；操作员改为在 PR 下发布精确的 `/approve <full-head-SHA>` 评论，由 n8n 通过 API 重新读取。这样可以绑定具体修订并留下可审计的第二次操作，但**不是独立审查**，不能称作独立审查。

## tea CLI 与 PAT 分派

`tea` 统一使用 Personal Access Token（`tea login add --token`），**不使用 OAuth**。原因是 Forgejo 对每个 `(user, application)` 只保留一个 OAuth grant，且默认 `[oauth2] INVALIDATE_REFRESH_TOKENS = true` 会轮换 refresh token：多台机器/容器用同一个内置 `tea` client id 登录时共用同一个 grant，互相把对方的 refresh token 顶掉（API 报 `token was already used`），最终只有一个能续期。

PAT 按使用者身份分派，不按设备或容器：

- `multica-gitops`、`multica-nix-packager`：各自的专用账号 PAT，分别注入对应的 `gitops-agent`、`nix-packager-agent` 工作区（私有仓 SOPS Secret 的 `FORGEJO_API_TOKEN`）。
- `beacon1096`（人类）：一个共享 PAT（最小 scope `write:repository`、`write:issue`、`read:user`），注入人类空间 `infra-maintainer` 与所有个人设备。工作区侧使用**专属** Secret `coder-workspace-infra-maintainer`（私有仓，与旧 `nixos-agent-coder` 使用的 `coder-workspace-agent` 隔离）的 `FORGEJO_API_TOKEN`，并以环境变量形式注入容器；个人设备侧经 `secrets/personal/forgejo.yaml`（`personal/forgejo/token`），由 `modules/home/forgejo.nix` 在 activation 时执行 `tea login add --token`。
- 没有专用 Agent 账号的 coder 工作区：不申请 PAT。

### 缺口

旧的 `nixos-agent-coder` 工作区在 Homelab 巡检迁出后，仍服务外部模型顾问 Agent（`专家: GPT 5.6 Sol xhigh`、`专家: Deepseek V4.1 Flash High`、`Pi Thor`）与 `Mika`。这些身份没有专用 Agent 账号与 PAT 接线；本轮刻意不处理。启用前需要先确定其身份归属，再按上面的分派补上。
