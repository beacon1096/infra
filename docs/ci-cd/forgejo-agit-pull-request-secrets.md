[中文](forgejo-agit-pull-request-secrets.md) | [English](forgejo-agit-pull-request-secrets_en.md)

# Forgejo AGit 合并请求与 Actions secrets

## 结论

需要使用仓库 Actions secrets 的 `pull_request` workflow 必须由普通同仓分支的合并请求触发。不要为这类变更使用 AGit flow。

在 Forgejo 14.0.3 中，即使 AGit 合并请求由仓库成员创建并指向同一仓库，Forgejo 仍会把它作为 fork pull request 运行。fork pull request 不会获得仓库 Actions secrets。

## 故障表现

典型表现如下：

- 只依赖公开输入或缓存的 job 可以成功。
- 使用 `INFRA_SSH_KEY`、`REPO_TOKEN` 等仓库 secret 的 job 很快失败。
- 重跑同一个 workflow 不会恢复，因为事件的 fork 属性没有改变。
- 汇总或 required job 随依赖 job 失败。

此时应先检查合并请求类型，不要先轮换凭据。

## 判定方法

查询合并请求：

```sh
tea api repos/OWNER/REPO/pulls/NUMBER \
  | jq '{flow, head: .head.ref, head_repo: .head.repo.full_name, base_repo: .base.repo.full_name}'
```

`flow: 1` 表示 AGit flow；普通分支合并请求为 `flow: 0`。

查询 Actions run：

```sh
tea api 'repos/OWNER/REPO/actions/runs?limit=20' \
  | jq '.workflow_runs[] | {id, event, status, is_fork_pull_request, html_url}'
```

如果失败的 run 同时满足 `event: "pull_request"` 与 `is_fork_pull_request: true`，且失败步骤需要仓库 secret，应按本页流程修复。

## 修复

1. 保留原提交，并将它推到目标仓库内的普通分支。
2. 关闭 AGit 合并请求。
3. 从该分支创建普通同仓合并请求，不传 `--agit`：

   ```sh
   git push origin HEAD:refs/heads/fix/example
   tea pr create --head fix/example --base main \
     --title 'fix: example'
   ```

4. 验证新合并请求的 `flow` 为 `0`，head 与 base 的 `repo.full_name` 相同。
5. 验证新 Actions run 的 `is_fork_pull_request` 为 `false`，再观察需要 secret 的 job。
6. 审批必须针对新合并请求的精确 head SHA；旧合并请求上的审批不能复用。

## 原因

Forgejo 14.0.3 的 pull request 模型把 AGit flow 标记为 fork flow。Actions 在准备 `pull_request` secrets 时会过滤 fork pull request 的仓库 secrets。因此问题发生在 workflow 启动前，workflow 文件中的环境变量声明无法修复它。

相关实现：

- [Forgejo 14.0.3 pull request flow](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.3/models/issues/pull.go)
- [Forgejo 14.0.3 Actions secret filtering](https://codeberg.org/forgejo/forgejo/src/tag/v14.0.3/models/secret/secret.go)

## 记录

2026-09-27，一次私有基础设施合并请求使用 AGit flow 创建。ARM job 因命中缓存而成功，x86 job 在使用 SSH secret 验证依赖仓库时失败。关闭 AGit 合并请求并以相同提交创建普通同仓合并请求后，新 run 被标记为非 fork，secret 检查与 ARM job 通过，x86 job 正常进入构建阶段。
