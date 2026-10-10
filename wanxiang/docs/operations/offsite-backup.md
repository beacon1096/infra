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

### 2026-10-10 — coder-pg 卷备份恢复演练（Coder 升级 2.36.5 前置门槛）

目的：验证万象 → 金银潭的 Longhorn 卷备份确实可恢复，而非仅有配置。

现状核对：

- 备份目标 `default` = `nfs://172.16.19.254:/mnt/beaco-01/Backups/wanxiang/longhorn`，
  经 `unifi_static_route.jinyintan_storage_via_ms-r1`（next_hop ms-r1
  `172.16.80.240`）到达金银潭存储；目标 `available=true`。
- 集群内仅存在 2026-09-17/18 k8s 升级前的 `SystemBackup` 一次性卷备份，
  没有 `RecurringJob`，也没有任何 CNPG `spec.backup` / `ScheduledBackup` /
  ObjectStore。即：当前所有 PG 集群都没有数据库级（barman/PITR）备份，
  卷备份也没有自动周期。

演练步骤（已执行）：

1. 对 `coder-pg` 主库卷 `pvc-74ad2fea-43dc-4941-a968-8fbb467627ba`
   （`coder-pg-4`）创建 `Snapshot` CR，再创建 `Backup` CR 上传金银潭。
2. 从 Backup `status` 取 `url` 与 `volumeSize`（`34359738368`）。
3. 在 `storage` 命名空间创建带 `spec.fromBackup` 的 `Volume` CR
   （`numberOfReplicas: 1`），等待 `status.restoreRequired=false`、
   `state=detached`。
4. 手工创建 PV/PVC（PV `volumeHandle` = Volume CR 名），在隔离命名空间
   挂载，用 `ghcr.io/cloudnative-pg/postgresql:18.3` 启动 PostgreSQL
   （执行 crash recovery）。
5. 校验：99 张表、`schema_migrations.version=421`、`users=4`、
   `workspaces=8`、`templates=3`、`organizations=1`、`workspace_agents=193`、
   `api_keys=41`，与生产主库一致；模板 `coding-agent` / `nixos-dev` /
   `swarm-01` 可读。
6. 演练资源（Volume/PV/PVC/Pod/命名空间）全部删除；金银潭上的备份保留。

结果：

- Longhorn 卷备份可恢复，`coder-pg` 数据在恢复后完整可读。
- 升级前恢复点：备份 `pre-coder-2-36-5-20261010`，卷
  `pvc-74ad2fea-43dc-4941-a968-8fbb467627ba`，创建于
  `2026-10-10T08:06:28Z`。
- RPO：手动触发；无自动周期，最近一次自动备份为 2026-09-18。
- RTO：卷恢复约 3.5 分钟（逻辑 27.6 GB / 增量约 58 MB），PostgreSQL
  启动与核对 <1 分钟；合计约 5 分钟（不含人工与 PV/PVC 组织）。

注意与限制：

- 卷备份是崩溃一致（crash-consistent）快照，不是事务一致性备份，也不
  支持 PITR；恢复依赖 PostgreSQL crash recovery。
- 备份的是单个副本卷；`coder-pg-5` 等较新副本卷尚无备份。应保证主库或
  至少一个副本卷有备份。
- 恢复出的数据目录权限为 `0770`，需 `chmod 0700` 后 PostgreSQL 才能启动；
  CNPG 自身恢复流程会处理该权限。
- 待办（建议独立 issue）：为关键 PG 集群配置周期备份（Longhorn
  `RecurringJob` 和/或 CNPG barman-cloud `ScheduledBackup`）并加失败告警。
