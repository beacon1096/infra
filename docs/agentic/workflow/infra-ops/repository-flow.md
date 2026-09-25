# infra 与 infra-private 的提交流转

## 仓库分工

`infra` 是 Forgejo 上的公开权威仓，GitHub 只镜像 `main`。可复用的公开基线在这里维护。`infra-private` 是独立私有仓，通过 `flake.lock` 固定一个已评审的 `infra` 修订，再叠加私有配置；依赖方向保持为 `infra` → `infra-private`。

```text
公开实现：工作分支 → PR → infra/main
                              │ 固定精确修订
                              ▼
私有组装：工作分支 → PR → infra-private/main
                              │ 发布审批与构建
                              ▼
                     infra-private/prod → Comin
```

## 普通变更如何进入 main

两个仓库的常规改动都从工作分支提交，并通过目标为对应仓库 `main` 的 PR 集成。仓内记录的 Forgejo 保护规则禁止直接推送到两个 `main`，要求 `policy/merge-gate`、`Check Secrets` 及 PR 所需的 CI 检查通过，并拒绝审查被否决或落后于目标分支的 PR。策略门禁把批准绑定到 PR 当前头部 SHA；`multica-merger` 是执行合并的账号。自己创建的 PR 使用 SHA 绑定的操作员确认时，这表示同一获授权主体确认了具体修订，不构成独立的第二人审查。

- `infra` 的 PR 运行 `Nix Validation` 和 `Check Secrets`。合入 `infra/main` 表示公开实现已集成，不表示已部署到生产。
- `infra-private` 的 PR 运行 `Check Secrets`；涉及对应路径时还运行 `Harness Checks`。合入 `infra-private/main` 后会执行完整机群构建；这一步验证私有组装结果，不部署到机群。
- 若私有配置需要某项公开实现，先将公开改动合入 `infra/main`，再在 `infra-private` 更新锁定的公开修订并提交 PR。只改私有行为时直接在 `infra-private` 提交。

保护规则通过 Forgejo API 管理，不由仓库文件声明；具体必需状态以 Forgejo 当前设置为准。当前规则的仓内记录见[Forgejo 服务账号](./forgejo-service-accounts.md)，SHA 绑定的审批和合并细节见[Renovate 与 Multica 合并门禁](./renovate-multica-gate.md)。

## 两个 prod 分支的含义

| 分支 | 如何更新 | 含义 |
| --- | --- | --- |
| `infra/prod` | `infra` 的发布标签构建完成后，由公开构建工作流将该标签对应的提交推到 `prod` | 公开仓的发布修订；不授权生产部署 |
| `infra-private/prod` | 常规发布成功后由私有构建工作流推进；紧急修复可走单独的 prod PR 门禁 | Comin 监视的生产部署输入 |

常规私有发布从经过 `infra-private/main` 验证的精确修订开始。运维手动触发完整构建，n8n 审批后为该修订创建发布标签；标签构建的所有发布作业成功后，Forgejo Actions 才更新 `infra-private/prod`。为保留生产分支上的热修复历史，自动化创建一个新晋级提交：它的文件树与标签修订相同，父提交是此前的 `prod` 头部，并在提交说明中记录 `Source-Commit`。因此，`prod` 头部提交 SHA 不一定等于发布标签的源提交 SHA。Comin 观察 `infra-private/prod` 并部署它的文件树。

紧急修复可以通过目标为 `infra-private/prod` 的 PR 进入。它使用独立的 `policy/prod-merge-gate` 和 `/approve-prod <完整头部 SHA>`；合入后会立即触发 Comin 部署，不经过常规标签发布的完整构建。不要把常规 `/approve`、`main` 门禁或 `infra/prod` 当作生产授权。生产分支保护也由 Forgejo API 管理，需确认当前规则单独要求 prod 门禁。

完整发布步骤见[生产发布与 Nix 部署](./production-release-and-rollout.md)。

## 需要核对的自动提交例外

私有仓的 `.forgejo/workflows/update-nchnroutes.yaml` 允许定时或手动运行；它在 `main` 上生成更新提交后执行 `git push origin HEAD:main`。这与仓内“`main` 禁止直接推送”的保护规则记录不一致。工作流文件只说明它尝试直接推送，不能证明 Forgejo 当前保护配置放行该操作；应核对实时分支规则，并统一选择改成 PR，或明确记录和限制该自动化例外。
