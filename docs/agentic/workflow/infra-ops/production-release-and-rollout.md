# 生产发布与 Nix 滚动部署

## 发布边界

- `infra/main` 是公开仓库的规范集成分支。其 CI 验证可复用模块和公开架构。
- `infra-private` 锁定 `infra` 的精确修订，并结合私有配置层组装完整的生产机群。
- 生产审批、发布标签、向 `prod` 推进以及 Comin 部署均由 `infra-private` 负责。
- `infra/prod` 由公开发布标签流程更新，不是生产部署分支。只有 `infra-private/prod` 是生产审批和 Comin 部署的输入；`infra` 中的标签不授权生产部署。
- 机群发布流水线沿用 `nix-fleet` 名称（CI concurrency group、Attic cache、OCI 包名）。本文所述发版流程即 `infra-private` 与 Nix-Fleet 流水线的生产发版流程。

普通改动如何经 PR 进入两个仓库的 `main`，见[仓库与分支提交流转](./repository-flow.md)。

## 发版入口

`infra-private` 机群的生产发版始终只有一条路径：运维人员手动触发 `build-and-push.yaml`（`workflow_dispatch`）→ 该运行成功后 n8n 钩子创建发布审批记录并发出审批表单 → 授权人类审批通过 → n8n 才为精确 SHA 创建发布标签并进入晋级构建。任何自动化都不能替代这条链。

- 合入 `main` 或推送到 `main` 而触发的 `build-and-push.yaml` 只做完整验证，不会创建审批记录、发布标签或推进 `prod`。发版不能只靠合并代码触发。
- 发布标签由 n8n 在人工审批通过后创建，运维人员不直接在 `main` 上手工打标。
- 目标为 `infra-private/prod` 的 PR 加 `/approve-prod` 是仅限紧急热修的例外路径，不是常规发版入口，也不能用来绕过上面的手动触发与人工审批。

## 流程

1. 公开变更在通过必要检查后合入 `infra/main`。
2. `infra-private` 更新锁定的公开仓库输入，并加入该修订所需的私有配置。
3. 推送到 `infra-private/main` 会运行完整机群构建。此步骤只做验证，不部署，也不会开始发版。
4. 运维人员手动运行 `build-and-push.yaml`（唯一的发版触发入口）。运行成功后，n8n 创建发布审批记录并发布审批表单。
5. 授权人类审批通过后，n8n 为经过审核的精确 SHA 创建 `infra-private` 发布标签。
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

紧急热修复（且仅限紧急热修）可以通过指向 `infra-private/prod` 的 PR 交付。这是常规发版之外唯一的例外路径，不得用于日常变更。这条路径使用独立的 `policy/prod-merge-gate`：所有必需检查全绿后，授权操作员在该 PR 下发布 `/approve-prod <完整 40 位头部 SHA>`，n8n 才请求即时 fast-forward 合并。提前评论不会排队；n8n 会把门禁恢复为 pending，操作员须在检查通过后发布新评论。`/approve` 和常规 Forgejo 审查都不批准生产 PR。合并会立即触发 Comin 部署；这条路径不经过标签发布的完整构建，因此只用于明确需要直接修复生产的变更。

## 拉取请求与分支的 OCI 验证

公开仓库按事件执行以下验证：

| 事件 | 静态检查与策略检查 | OCI 归档构建 | Registry 发布 | 凭据 |
| --- | --- | --- | --- | --- |
| 拉取请求 | Flake 求值、n8n 策略测试，以及 `skopeo` 命令回归检查 | 构建 `coding-agent-oci`、`multica-backend-oci`、`coder-server-oci` | 无 | 无 Attic 或 Registry 写入凭据 |
| 推送到 `main` 以外的分支 | 与拉取请求相同的检查 | 构建三个 OCI 归档 | 无 | 无 Attic 或 Registry 写入凭据 |
| 推送到 `main` | 验证工作流及完整的 `build-and-push.yaml` 作业图 | 完整的发布构建作业图（仅构建/检查） | 无 | 无 Registry 写凭据 |
| 推送标签 | 完整的 `build-and-push.yaml` 作业图 | 完整的发布构建作业图（仅构建/检查） | 无 | 无 Registry 写凭据 |
| 手动触发完整构建 | 运维人员通过 `build-and-push.yaml` 选择引用 | 完整的发布构建作业图（仅构建/检查） | 无 | 无 Registry 写凭据（仅 Attic 缓存读/写） |

容器发布回归检查会拒绝无效的 `skopeo --authfile ... copy` 参数顺序，并验证已安装的 `skopeo copy` 支持 `--dest-authfile`。这样可以在涉及凭据或大型镜像归档之前发现命令行错误。

必需检查 `Nix Validation / nix-evaluation (pull_request)` 会构建 `coding-agent-oci`、`multica-backend-oci` 和 `coder-server-oci`。拉取请求作业既拿不到 Attic 写入凭据，也拿不到 Registry 凭据：它们只能证明 OCI 归档可以求值和构建，不能发布任何产物。

公开仓 `check-nix.yaml` 与 `build-and-push.yaml` 只对 OCI 归档执行 `nix build`/inspect，不执行任何 `skopeo copy`，也不引用任何 registry 写凭据。此前公开仓用于分支试发布的 `ci-publisher/nix-fleet/*:ci-scratch` 标签及其 `CI_REGISTRY_*` 凭据已移除；公开 CI 现在完全不具备 registry 写权限。

求值成功并不意味着拉取请求可以合并。OCI 构建在现有的必需检查上下文 `Nix Validation / nix-evaluation (pull_request)` 中运行，因此任一归档构建失败，受保护分支的该项检查都会失败。

## 镜像发布权

生产镜像 `infrastructure/nix-fleet/{coding-agent,multica-backend,coder,forgejo-runner-nix,sing-box}` 的唯一 publisher 是 `infra-private`。公开仓保留这些镜像的包与 derivation（作为可复用的公开定义），但不再发布镜像；`infra-private` 通过锁定的 `infra` input 引用公开定义构建并推送，不复制镜像定义。

每次发布时，`infra-private` 先推由私有发布器修订与锁定的公开修订派生的不可变 tag（`private-<private-rev>-infra-<infra-rev>`），从 registry 读取并记录 digest 后，才移动 `latest`、下游版本 tag 与发布 tag；构建摘要与 digest 记录写入镜像路径、flake attr、Nix store path、两个修订、不可变 tag 与最终 digest，并作为 artifact 保存，供回滚与审计使用。Coder 生产模板消费已确认的不可变 digest（`coding-agent` 已 pin；`nixos-dev` 的 `:latest`、runner 主容器与 seed initContainer 仍待收敛/核对）。

历史公开仓 `nix-fleet` 处于观察期：本项不修改、不归档该仓库，其残留的 workflow 与写 secret 在禁用前不作为「唯一 publisher」验收的例外计入，待观察期结束单独处理。

## 信任与回滚

n8n 是受信任的发布控制平面的一部分：它已有审批后创建 `infra-private` 标签的能力。重建标签对应的修订后，由 Forgejo Actions 而非 n8n 推进 `prod`。Comin 仅受信任部署 `prod` 上可见的修订。

回滚意味着选定一个经过审核、已知正常的 `infra-private` 修订，执行相同的发布流程，并通过成功的标签构建推进 `prod`。不要绕过发布工作流移动 `prod` 来修复失败的部署。
