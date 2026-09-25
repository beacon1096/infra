# 生产发布与 Nix 滚动部署

## 发布边界

- `infra/main` 是公开仓库的规范集成分支。其 CI 验证可复用模块和公开架构。
- `infra-private` 锁定 `infra` 的精确修订，并结合私有配置层组装完整的生产机群。
- 生产审批、发布标签、向 `prod` 推进以及 Comin 部署均由 `infra-private` 负责。
- `infra/prod` 由公开发布标签流程更新，不是生产部署分支。只有 `infra-private/prod` 是生产审批和 Comin 部署的输入；`infra` 中的标签不授权生产部署。

普通改动如何经 PR 进入两个仓库的 `main`，见[仓库与分支提交流转](./repository-flow.md)。

## 流程

1. 公开变更在通过必要检查后合入 `infra/main`。
2. `infra-private` 更新锁定的公开仓库输入，并加入该修订所需的私有配置。
3. 推送到 `infra-private/main` 会运行完整机群构建。此步骤只做验证，不部署。
4. 运维人员手动运行 `build-and-push.yaml`。运行成功后，n8n 创建发布审批记录并发布审批表单。
5. 审批通过后，n8n 为经过审核的精确 SHA 创建 `infra-private` 发布标签。
6. 标签触发再次完整构建并发布产物。只有所有发布作业都成功后，Forgejo Actions 才会创建晋级提交并更新 `infra-private/prod`：该提交沿用此前 `prod` 头部作为父提交，文件树与发布标签修订相同，提交说明记录 `Source-Commit`。
7. Comin 监视 `infra-private/prod`，并将该修订部署到 NixOS 机群。

```text
infra/main
    │ 锁定的修订
    ▼
infra-private/main ── 完整验证 ── n8n 审批
                                            │ 精确 SHA 标签
                                            ▼
                                     发布构建
                                            │ 所有作业成功
                                            ▼
                         infra-private/prod 晋级提交
                                            │ Comin
                                            ▼
                                      NixOS 机群
```

切勿直接推送 `prod`。发布标签是常规晋级的授权记录，不只是版本标记。发布构建失败或只有部分成功时，`prod` 必须保持不变。

紧急热修复可以通过指向 `infra-private/prod` 的 PR 交付。这条路径使用独立的 `policy/prod-merge-gate`：所有必需检查全绿后，授权操作员在该 PR 下发布 `/approve-prod <完整 40 位头部 SHA>`，n8n 才请求即时 fast-forward 合并。提前评论不会排队；n8n 会把门禁恢复为 pending，操作员须在检查通过后发布新评论。`/approve` 和常规 Forgejo 审查都不批准生产 PR。合并会立即触发 Comin 部署；这条路径不经过标签发布的完整构建，因此只用于明确需要直接修复生产的变更。

## 拉取请求与分支的 OCI 验证

公开仓库按事件执行以下验证：

| 事件 | 静态检查与策略检查 | OCI 归档构建 | Registry 发布 | 凭据 |
| --- | --- | --- | --- | --- |
| 拉取请求 | Flake 求值、n8n 策略测试，以及 `skopeo` 命令回归检查 | 构建 `coding-agent-oci` 和 `multica-backend-oci` | 无 | 无 Attic 或 Registry 写入凭据 |
| 推送到 `main` 或 `prod` 以外的分支 | 与拉取请求相同的检查 | 构建两个 OCI 归档 | 覆盖两个 `ci-scratch` 标签 | 仅有软件包权限的 `CI_REGISTRY_*` 凭据 |
| 推送到 `main` | 验证工作流及完整的 `build-and-push.yaml` 作业图 | 完整的发布构建作业图 | 发布常规镜像标签 | 生产凭据，仅供发布步骤使用 |
| 推送标签 | 完整的 `build-and-push.yaml` 作业图 | 完整的发布构建作业图 | 发布常规标签和发布标签 | 生产凭据，仅供发布步骤使用 |
| 手动触发完整构建 | 运维人员通过 `build-and-push.yaml` 选择引用 | 完整的发布构建作业图 | 发布常规镜像标签 | 使用生产凭据的特权运维操作 |

容器发布回归检查会拒绝无效的 `skopeo --authfile ... copy` 参数顺序，并验证已安装的 `skopeo copy` 支持 `--dest-authfile`。这样可以在涉及凭据或大型镜像归档之前发现命令行错误。

必需检查 `Nix Validation / nix-evaluation (pull_request)` 会构建 `coding-agent-oci` 和 `multica-backend-oci`。拉取请求作业既拿不到 Attic 写入凭据，也拿不到 Registry 凭据：它们只能证明 OCI 归档可以求值和构建，不能发布任何产物。

直接推送到 `main` 或 `prod` 以外的分支时，会重复这些构建，然后实际登录 Forgejo Registry 并执行 `skopeo copy`。它会覆盖以下共用、可随时丢弃的标签：

- `ci-publisher/nix-fleet/coding-agent:ci-scratch`
- `ci-publisher/nix-fleet/multica-backend:ci-scratch`

这些标签不保证保留，生产环境或晋级自动化绝不能使用它们。共用标签省去了定时清理任务；并发运行时，以最后一次写入为准，但每个成功作业仍能证明自身上传已完成。只有 `refs/heads/*` 推送事件可以执行此项试发布，因此标签事件不能写入临时标签。`main`、发布标签和手动授权的完整构建仍只通过 `build-and-push.yaml` 发布。

求值成功并不意味着拉取请求可以合并。OCI 构建在现有的必需检查上下文 `Nix Validation / nix-evaluation (pull_request)` 中运行，因此任一归档构建失败，受保护分支的该项检查都会失败。分支推送检查还能区分 Registry 认证或传输故障与拉取请求构建故障，同时不会向拉取请求事件暴露其凭据。

分支推送工作流会执行由分支控制的代码，因此只有已获信任、能够直接推送到此仓库的主体才能获得临时发布者凭据。该凭据仍受隔离：`ci-publisher` 仅在自己的命名空间内拥有软件包写入权限，无权访问仓库或 `infrastructure` 组织。拉取请求事件绝不会获得该凭据。

## 信任与回滚

n8n 是受信任的发布控制平面的一部分：它已有审批后创建 `infra-private` 标签的能力。重建标签对应的修订后，由 Forgejo Actions 而非 n8n 推进 `prod`。Comin 仅受信任部署 `prod` 上可见的修订。

回滚意味着选定一个经过审核、已知正常的 `infra-private` 修订，执行相同的发布流程，并通过成功的标签构建推进 `prod`。不要绕过发布工作流移动 `prod` 来修复失败的部署。
