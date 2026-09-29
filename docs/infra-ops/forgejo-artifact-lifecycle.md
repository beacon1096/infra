# Forgejo 产物生命周期

`forgejo-data` PVC 曾用到 95%，其中约 78 GiB 是发布产物、约 14 GiB 是容器包，且都没有保留策略。本页记录各类产物的生命周期机制，以及无法由仓库声明式管理、只能通过 Forgejo 运行时状态维护的部分。

| 产物 | 位置 | 机制 | 声明式？ |
| --- | --- | --- | --- |
| Installer ISO | Forgejo release asset | `.forgejo/workflows/prune-forgejo-release-assets.yaml` 定时清理 | 是（workflow） |
| 容器包版本 | Forgejo packages | 组织「清理规则」 | **否**（运行时 DB） |
| Actions artifacts / logs | Forgejo actions | `app.ini`（forgejo HelmRelease） | 是（helmrelease） |
| Nix closure | Attic | 暂无 GC | 未实现 |
| Git 仓库 | Forgejo | — | — |

## Installer ISO（release asset）

`build-and-push.yaml` 在每个 tag 都把 `nixos-minimal-*.iso`（约 1.4 GiB）上传成 release asset。Forgejo 没有 release asset 的保留机制，仓库设置里也没有对应项。

`infra` 与 `infra-private` 各自新增 `.forgejo/workflows/prune-forgejo-release-assets.yaml`：每周日清理，保留**每个仓库最新 3 个 release** 的 asset，只删 asset，保留 tag 和 release 记录。`workflow_dispatch` 支持 `keep`（默认 3）和 `dry_run`。

## 容器包版本

Forgejo 的包清理规则是 **owner 级**的运行时状态（表 `package_cleanup_rule`），由 `cron.cleanup_packages` 执行；没有 REST API，`forgejo-helm` 也没有对应的 values，因此**无法在 Terraform 或仓库里声明**。

当前规则：

| 字段 | 值 |
| --- | --- |
| Owner | `infrastructure`（组织） |
| Type | `container` |
| 启用 | 是 |
| 保留 | 每个软件包最新 5 个版本 |

容器类型始终保留 `latest`，不受保留数量影响。

- 查看与修改：<https://forgejo.beaco.works/org/infrastructure/settings/packages> → 「清理规则」。
- UI 中保留数量只允许 `0/1/5/10/25/50/100`；`0` 表示不保留旧版本（仅 `latest`）。
- 规则存在 `forgejo.db` 里。重建或从导出恢复该数据库后规则会丢失，需要重新创建。

## Actions artifacts 与 logs

`infra` 的 `wanxiang/kubernetes/apps/development/forgejo/app/helmrelease.yaml` 设置了：

- `[actions] ARTIFACT_RETENTION_DAYS=14`、`LOG_RETENTION_DAYS=30`；
- 显式启用 `cron.cleanup_actions` 与 `cron.cleanup_packages`。

管理员手动入口：

- `/admin/packages`：清理 unreferenced blob 与过期数据；
- `/admin/monitor/cron`：查看并手动触发 cron 任务（不能改计划）。

已知问题：Forgejo 14.0.3 上手动触发 `cleanup_actions` 并不会删除已过期的 artifact，部署后需要复核。

## Attic

`attic-store`（100 GiB）只增不减，上游 attic 没有内置 GC，属单独的后续工作。

## 验证

```bash
kubectl -n development exec deploy/forgejo -- df -h /data
kubectl -n development exec deploy/forgejo -- du -sh /data/attachments /data/packages /data/git
```

查看某仓库的 release asset（`REPO_TOKEN` 来自 Forgejo Actions）：

```bash
curl -fsSL -H "Authorization: token $TOKEN" \
  "https://forgejo.beaco.works/api/v1/repos/infrastructure/infra-private/releases?limit=50" |
  jq '[.[] | {tag: .tag_name, assets: [.assets[].name]}]'
```
