# 数据库与卷备份（万象）

本页说明万象集群上 Coder PostgreSQL（`coder-pg`，以及其它 CNPG 集群）的
备份层级、目标、保留策略、告警与恢复流程。精确的备份目标 URL、主机、路由、
恢复密钥和演练数据记录在 `infra-private`，本页不记录。

## 备份层级

- **L1 卷级（灾难恢复）**：Longhorn `RecurringJob` `daily-backup` 对每个卷做
  增量快照并上传到异地备份目标。覆盖整卷数据（含 CNPG 数据目录），用于整个
  集群站点不可用时的恢复。
- **L2 应用级（一致性与 PITR）**：CloudNativePG 的 Barman ObjectStore（WAL
  归档 + 基础备份）。**当前未启用**，因此没有时间点恢复（见「取舍」）。

## 目标

- **RPO**：24 小时（Longhorn 每日备份）。因未启用数据库级 PITR，暂无分钟级 RPO。
- **RTO**：约 5 分钟（卷恢复 + 隔离命名空间挂载 + PostgreSQL crash recovery，
  实测见 BEACO-202 演练记录）。

## 保留、并发与容量预算

- 保留：每卷 14 个恢复点（`retain: 14`）；`full-backup-interval: 6` 表示每 7
  次备份强制一次全量，用于在内容寻址存储出现坏块时重写，同时限制全量上传次数。
- 并发：`concurrency: 1`，同一时刻只备份一个卷，避免占满异地链路。
- 窗口：每日 02:00 CST。Longhorn 以 UTC 评估 cron，故为 `0 18 * * *`。
- 容量：集群卷配置总量约 1.92 TiB、实际用量约 863 GiB；异地数据集配额 4 TiB。
  LZ4 压缩与内容寻址去重后，最坏情况（保留窗口内含 2 次全量）约 2 TiB，仍有
  余量。超配额会阻断备份，需监控异地数据集用量。
- 传输约束：异地链路当前受叠加网 PMTU/递归路由影响，实测吞吐可能远低于链路
  标称值；持久修复完成前，全量备份可能耗时很长。链路细节见 `infra-private`。

## 取舍：先做 Longhorn，而非 CNPG PITR

- Longhorn 卷备份完全声明式、无需数据库凭据、覆盖整卷、恢复路径简单，适合作
  为灾难恢复层。
- CNPG/Barman 提供应用一致性与 PITR，但需要 S3 兼容对象存储（endpoint、
  bucket、凭据）；万象异地的备份目标目前只有 NFS，Barman 不支持 NFS。
- 结论：先落地 Longhorn 周期备份，满足 RPO 24h；PITR 需要先在异地提供 S3
  兼容目标（例如 MinIO），并在 `infra-private` 保存凭据，作为后续独立 issue。

## 可观测与告警

- `RecurringJob.status` 记录成功/失败历史（`recurring-failed-jobs-history-limit`），
  Longhorn 也会为备份进度与结果发 Kubernetes Event。
- `PrometheusRule longhorn-backup`（`storage` 命名空间）定义两条告警：
  - `LonghornBackupStale`：某卷超过 2×RPO 没有成功备份。
  - `LonghornBackupFailed`：`Backup` 进入 Error 状态。
- 依赖：集群尚未运行 Prometheus/VictoriaMetrics 与 Alertmanager。Longhorn
  `ServiceMonitor` 与上述规则已声明，指标栈落地后告警立即生效；在此之前以
  「日常检查」与 Longhorn 事件作为观测手段。仅创建 CR 不等于备份成功。

## 日常检查

1. `kubectl -n storage get recurringjobs.longhorn.io daily-backup` 确认任务存在。
2. `kubectl -n storage get backupvolumes.longhorn.io` 查看各卷最新备份时间。
3. `kubectl -n storage get backuptargets.longhorn.io default` 确认 `AVAILABLE=true`。
4. Longhorn UI → Recurring Jobs / Backups 查看失败历史，关注
   `BackupTargetUnavailable` 事件。
5. 确认异地加密数据集已解锁、未逼近配额（主机与路径见 `infra-private`）。

## 恢复演练 runbook

1. 选定恢复点：`kubectl -n storage get backups.longhorn.io`（或 BackupVolume
   的 `lastBackupName`）。
2. 用 `fromBackup` 新建一次性卷/PVC 到隔离命名空间，等待 `restoreRequired=false`。
3. 挂载到临时 Pod，核对内容（数据库目录、表数量、关键行）。CNPG 数据目录可用
   一个临时 PostgreSQL 实例做 crash recovery 验证。
4. 记录恢复耗时（RTO）；随后删除演练命名空间、卷、PVC 与 Pod，确认生产
   `coder-pg` 保持 healthy。
5. 破坏性变更前确认异地最新恢复点的时间与覆盖范围；未经恢复验证的备份不视为
   可用。

> 注意：`allow-recurring-job-while-volume-detached=false`（当前设置）。已停止的
> 工作负载其分离的卷不会被备份；关键数据库卷始终 attached，不受影响。

## 关联

- BEACO-202（Coder 升级前的备份验证与恢复演练）
- BEACO-203（周期备份、告警与本次落地）
