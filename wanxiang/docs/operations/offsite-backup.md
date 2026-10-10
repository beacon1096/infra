# 万象异地备份

万象将 Longhorn 卷备份和集群元数据存放在集群站点之外。备份端点、访问路径、恢复密钥和主机操作步骤记录在 `infra-private`。

## 叠加网络传输

即使到某个叠加网络对端的路由实际经过另一台叠加网络子网路由器，对端仍可能显示为“直连”。这会让传输流量再次进入同一叠加网络。额外封装降低路径 MTU，大型备份可能因此出现严重分片和重传。

临时降低叠加网络接口的 MTU 有助于诊断，但不能消除递归路由。长期修复是阻止叠加网络自身带标记的传输包选择已确认会递归的端点，同时保留普通应用流量和真正可用的底层路由。私有路由细节、测量结果和上线检查记录在私有基础设施库存中。

## 备份验证

依赖异地备份目标前，应完成以下检查：

1. 确认加密存储已解锁，集群可以访问其备份服务。
2. 确认 Longhorn 将备份目标报告为可用。
3. 使用 `volumeBackupPolicy: always` 创建 `SystemBackup`，等待其引用的所有卷备份完成。
4. 定期恢复一个可丢弃的测试卷并核对内容。只有备份清单不等于完成恢复测试。

Longhorn 卷备份和 `SystemBackup` 对象覆盖卷数据与集群元数据。需要时间点恢复的应用还应具备自身的备份方案。

## 恢复演练记录

### 2026-10-10 — coder-pg 卷备份恢复演练（Coder 升级前置门槛）

目的：验证万象 → 金银潭的 Longhorn 卷备份确实可恢复，而非仅有配置。备份端点、
访问路径、路由与恢复密钥等具体信息见私有仓 `infra-private`。

现状核对：

- 备份目标 `default` 指向金银潭存储，状态为 available。
- 集群内仅存在 2026-09-17/18 k8s 升级前的一次性 `SystemBackup` 卷备份；
  没有 `RecurringJob`，也没有任何 CNPG `spec.backup` / `ScheduledBackup` /
  ObjectStore。即：所有 PG 集群都没有数据库级（PITR）备份，卷备份也没有
  自动周期。

演练步骤（概要）：

1. 对 `coder-pg` 主库卷创建 `Snapshot` + `Backup`，上传金银潭。
2. 从 Backup `status` 取 `url` 与 `volumeSize`。
3. 在 `storage` 命名空间创建带 `spec.fromBackup` 的 `Volume` CR（单副本），
   等待恢复完成（`restoreRequired=false`）。
4. 以该卷 `volumeHandle` 手工创建 PV/PVC，在隔离命名空间挂载，用与集群一致
   的 PostgreSQL 镜像启动（执行 crash recovery）。
5. 校验 schema、用户、模板与 workspace 元数据可读，且与生产主库一致；具体
   对象与计数记录在 `infra-private`。
6. 演练资源全部删除；金银潭上的备份保留。

结果：

- Longhorn 卷备份可恢复，`coder-pg` 数据在恢复后完整可读。
- 升级前恢复点：备份 `pre-coder-2-36-5-20261010`（2026-10-10）。
- RPO：手动触发；无自动周期，最近一次自动备份为 2026-09-18。
- RTO：卷恢复约 3.5 分钟，PostgreSQL 启动与核对 <1 分钟，合计约 5 分钟。

注意与限制：

- 卷备份是崩溃一致（crash-consistent）快照，不是事务一致性备份，也不支持
  PITR；恢复依赖 PostgreSQL crash recovery。
- 备份的是单个副本卷；较新的副本卷可能尚无备份。应保证主库或至少一个副本卷
  有备份。
- 恢复出的数据目录权限需校正后 PostgreSQL 才能启动；CNPG 自身恢复流程会处理
  该权限。
- 待办见 BEACO-203（周期备份、PITR 与失败告警）。
