# Forgejo 服务账号

自动化使用相互独立、权限受限的 Forgejo 账号，避免依赖发现、策略判断和合并操作共用凭据。

| 用户名 | 邮箱 | 用途 | 仓库权限 |
| --- | --- | --- | --- |
| `renovate` | `renovate@noreply.forgejo.beaco.works` | 发现依赖更新并创建 PR | `infrastructure/infra` 和 `infrastructure/infra-private` 的写入协作者 |
| `multica-gate` | `multica-gate.no-reply@beacoworks.xyz` | 读取 PR，写入 `policy/merge-gate` 或 `policy/prod-merge-gate` 提交状态 | 两个基础设施仓库的写入协作者 |
| `multica-merger` | `multica-merger.no-reply@beacoworks.xyz` | 满足受保护分支要求后合并 PR | 两个基础设施仓库的写入协作者 |
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

修改仓库的 Multica Agent 最终应拥有独立运行身份，而不是继承一套共享工作区配置。这项工作独立于合并门禁，尚未完成。

每个 Agent 配置至少应隔离：

- Nix 配置、substituter、受信任密钥、构建机和缓存；
- Git 作者名、免回复邮箱、签名策略和凭据助手；
- 需要写入仓库时使用的专用 Forgejo 账号和最小权限 PAT；
- 仓库允许列表，以及读取、推送分支、创建 PR、审查 PR 等操作权限；
- 缓存、home 和临时目录，避免全局 `gitconfig`、Nix 状态或凭据在 Agent 之间泄漏。

确定后的账号名和免回复邮箱应记录在本文；令牌与私有签名材料仍保留在相应的秘密存储中。Agent 身份不能复用 `renovate`、`multica-gate` 或 `multica-merger`，因为它们分别负责依赖发现、策略判断和合并。

在独立身份建立前，经明确授权的 Agent 可以使用 `beacon1096` 身份。Forgejo 和合并门禁必然将其视为与人类操作员相同的主体。由这一共享身份创建的 PR 无法在 Forgejo 中自我审查；操作员改为在 PR 下发布精确的 `/approve <full-head-SHA>` 评论，由 n8n 通过 API 重新读取。这样可以绑定具体修订并留下可审计的第二次操作，但**不是独立审查**，不能称作独立审查。
