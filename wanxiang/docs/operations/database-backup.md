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

- 保留：每卷 14 个恢复点（`retain: 14`）；`full-backup-interval: 6` 表示每 6
  次 Job 运行强制一次全量（`executionCount % 6 == 0`），用于在内容寻址存储出现
  坏块时重写，同时限制全量上传次数。
- 并发：`concurrency: 1`，同一时刻只备份一个卷，避免占满异地链路。
- 队首阻塞：一次 `daily-backup` Job 顺序处理卷；某个卷上传卡住会推迟同一次
  Job 中排在后面的所有卷。判断任务健康要看 Job 运行时长和逐卷
  `lastBackupAt`，不能只看 Job 是否最终 `Complete`。
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

- Kubernetes Job 的成功只表示 recurring-job 控制器完成了遍历；卷级上传失败时
  Job 仍可能是 `succeeded=1`。必须逐卷核对最新 `Backup.status.state`、`error` 与
  `snapshotCreatedAt`。Longhorn 也会为备份进度与结果发 Kubernetes Event。
- `PrometheusRule longhorn-backup`（`storage` 命名空间）定义两条告警：
  - `LonghornBackupStale`：某卷超过 2×RPO 没有成功备份。
  - `LonghornBackupFailed`：`Backup` 进入 Error 状态。
- 依赖：集群已运行 Prometheus/Alertmanager。Longhorn `ServiceMonitor` 与上述规则
  已声明，但告警是否可用取决于 Prometheus 能否真正抓取 `longhorn-backend`
  指标端点。仅创建 CR 或规则不等于告警生效。
- 已知抓取缺口（2026-10-18）：`storage` NetworkPolicy `longhorn-manager` 的
  ingress 只允许 Longhorn 自身组件，`monitoring` 命名空间的 Prometheus 不在
  允许列表，三个 `longhorn-manager:9500/metrics` 目标均为 `down`
  （`context deadline exceeded`）。在放行该抓取前，`LonghornBackupStale` /
  `LonghornBackupFailed` 不会触发，备份异常只能靠日常检查与 Longhorn Event
  发现。修复后必须验证 `up{job="longhorn-backend"} == 1` 再依赖上述告警。

## 日常检查

1. `kubectl -n storage get recurringjobs.longhorn.io daily-backup` 确认任务存在。
2. `kubectl -n storage get backupvolumes.longhorn.io` 查看各卷最新备份时间。
3. `kubectl -n storage get backuptargets.longhorn.io default` 确认 `AVAILABLE=true`。
4. Longhorn UI → Recurring Jobs / Backups 查看失败历史，关注
   `BackupTargetUnavailable` 事件。
5. 确认异地加密数据集已解锁、未逼近配额（主机与路径见 `infra-private`）。
6. 对 OpenStatus 使用 `MAX_BACKUP_AGE_HOURS=26 bash
   utils/check-openstatus-backups.sh`；脚本非零退出即表示 Secret、升级和上线恢复门槛
   未满足。不要用 Job `succeeded` 或 BackupTarget `available` 代替逐卷结果。
7. 检查当前 `daily-backup-<timestamp>` Job 的运行时长与 `Backup` 是否推进：
   `kubectl -n storage get jobs | grep daily-backup`、
   `kubectl -n storage get backups.longhorn.io -o wide`。正常运行约 40 分钟；
   超过数小时通常表示链路降级或某个卷卡住，需先处理队首卷。

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

## 故障记录

### 2026-10-17 — 金银潭 NFS 无响应导致卷备份 I/O 错误

- 2026-10-17 20:38 UTC，ms01-a 内核记录多条
  `nfs: server 172.16.19.254 not responding, timed out`；20:39
  `backup-56ffa8f38a634c66`（`nix-collector/forgejo-runner-nix`，300Gi）
  在 24% 处以 `input/output error` 失败。同类超时还出现在 2026-10-15 02:21
  和 2026-10-17 18:09（ms01-c），说明不是单节点 mount 配置问题。
- 备份 mount 为 `soft,timeo=300,retrans=2`，服务端超过 30 秒无响应时内核以
  EIO 结束写操作；因此备份错误是链路/服务端无响应的结果，不是 Longhorn 或
  CSI 逻辑故障。
- 后续影响：同一次 Job 中下一个大卷（`development/forgejo-data`，100Gi）在
  21:49 开始后长时间停在约 56%；Job 持续 7 小时以上仍未完成（基线约 40
  分钟），其余约 20 个卷的当日恢复点被推迟，`coder-pg-4` 因此落后于
  `coder-pg-2/-5`。
- 处置要点：先在金银潭侧核对 NFS 服务与磁盘健康，再处理卡住的卷；不要在链路
  仍抖动时提高 `concurrency`，那会加重异地链路和 NFS 排队。

### 2026-10-18 — 同一 Job 持续 19 小时未结束（续报）

- `daily-backup-29871000`（2026-10-17 18:00 UTC 启动）到 10-18 13:20 仍在运行。
  该批次命中 `full-backup-interval`，创建的是全量备份（对比
  `backup-a7b80166` 的 `spec.backupMode=full`）；`concurrency: 1` 下全量上传把
  单次 Job 拉长到 19 小时以上。
- 队首卷：`nix/attic-store`（100Gi）的 `backup-322cf123` 自 04:38 起停在
  18–19%，`lastSyncedAt` 为空。其副本在 ms01-a；该节点备份 mount 可写（实测
  约 5 MB/s）、异地数据集空间充足（4.0T 用 307G），但备份进度几乎不推进。
- 逐卷核对：19 个卷最新恢复点仍为 2026-10-16，含 `forgejo-data`、`attic-store`、
  `registry/zot`、`authentik-pg-4/-6` 与 `coder-pg-4`。`BackupTarget/default`
  全程 `available=true`，只看目标状态会漏掉该故障。
- 临时处置：2026-10-18 13:51 UTC 对 `development/coder-pg-4` 手动执行 Snapshot +
  `snapshotBackup`，产生 `backup-dcbdfb06de7d433e`（Completed），恢复其 24h
  RPO。手动备份不带 `RecurringJob` 标签，不会被 `retain` 清理。
- 未决：CronJob 为 `ForbidConcurrent`。若 10-17 的 Job 在 10-18 18:00 UTC 前
  仍不结束，当日批次会被跳过，其余 18 个卷的 RPO 将超过 48 小时。是否中止该
  Job，以及全量批次的并发与排程调整，需在链路恢复后单独批准。

## 关联

- BEACO-202（Coder 升级前的备份验证与恢复演练）
- BEACO-203（周期备份、告警与本次落地）
