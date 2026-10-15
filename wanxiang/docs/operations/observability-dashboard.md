# 万象平台最小仪表盘与查询手册

本页和
`kubernetes/apps/monitoring/prometheus-stack/dashboards/wanxiang-platform-overview.json`
是 BEACO-216 的可导入准备产物。它基于公开 #259 的准确版本
`c9084b2439fd64e07baaa14b2f3f78335d4034bc`；没有启用 Grafana、没有加入
Flux 父级，也不包含通知端点或凭据。

## 展示环境与最短预览步骤

需要一个支持 dashboard `schemaVersion: 39` 的 Grafana，以及一个指向 #259
Prometheus 的 datasource。只查看查询时也可以直接使用 Prometheus expression browser，
不需要 Grafana。

离线验证无需集群、Grafana 或网络通知：

```bash
bash utils/run-observability-test.sh
```

该命令会解析实际 dashboard JSON，从仓库 `flake.lock` 取得固定 promtool，使用同一组
查询依次验证 0 分钟正常、1 分钟故障、2 分钟无数据、3 分钟恢复。查询或 Grafana 的
Unknown 映射发生漂移时测试会失败。

可视预览只需：

1. 在隔离/已获准的 Grafana 进入 **Dashboards → New → Import**。
2. 上传 `wanxiang-platform-overview.json`，将唯一的 `DS_PROMETHEUS` 输入选择为目标
   Prometheus datasource。
3. 打开 **Wanxiang Platform Overview**，时间范围保持默认六小时。顶部三个证据面板
   必须先显示 Healthy/Present；橙色 Unknown 必须按下文排查，不能解释为健康。

导入操作只创建 Grafana dashboard；本准备包没有 Grafana Pod、Flux 引用或 dashboard
sidecar。未来若采用 GitOps provisioning，必须另行提交连接该 JSON 的明确变更，不能
顺带启用当前准备目录。

## 真实 schema 与面板解释

| 层次 | 查询/标签 | 正常 | 故障 | 无数据 |
|---|---|---|---|---|
| 采集 | 最终 `up{job=~"node-exporter|longhorn-backend|monitoring/cnpg-instances|monitoring/cnpg-operator|network/envoy-proxy|cert-manager|cainjector|webhook"}` | 所有值为 1 | 任一值为 0 | 全部目标消失时 Collection state=Unknown |
| 目标发现 | `kube_pod_container_status_ready` 按 `namespace,pod` 与最终 `up` 对账；该 KSM 2.18 指标没有 `condition` 标签 | Ready Pod 都有目标 | Ready Pod 没有对应目标 | KSM 指标本身缺失时 Discovery state=Unknown |
| 节点 | `kube_node_status_condition{condition="Ready",status="true"}`、`node_uname_info` | Ready=1 | Ready=0 | 指标缺失为 Unknown |
| 磁盘 | `node_filesystem_avail_bytes / node_filesystem_size_bytes`，排除 tmpfs/overlay/squashfs 与 Pod mount | 余量 ≥25% | <15% 红色 | 任一计算输入缺失则无样本/Unknown |
| Longhorn | `longhorn_volume_robustness{state="faulted"}`；1.12.1 中 faulted 的值为 1 | 0 | 1 | 无样本为 Unknown |
| 逐卷备份 | `longhorn_volume_last_backup_at`、`longhorn_backup_state`，标签为 `volume,pvc,pvc_namespace` | 最近成功时间 <24h，state 非 4 | >48h 或 state=4 | 时间序列缺失为 Unknown；Job succeeded 不替代本证据 |
| CNPG | `cnpg_collector_last_collection_error`、`cnpg_pg_replication_lag`、`cnpg_collector_collection_duration_seconds` | error=0、lag≤300s | error=1 或 lag>300s | collector 证据缺失为 Unknown |
| 网关 | `envoy_server_live` | 1 | 0 | 无样本为 Unknown |
| 证书 | `certmanager_certificate_expiration_timestamp_seconds` | 剩余≥14天 | <14天 | 无样本为 Unknown |

顶部 **Metric evidence state** 同时要求 node/KSM、Longhorn、CNPG、Envoy 和
cert-manager 的关键 metric family 存在，并逐对象对账 node-exporter identity、Longhorn
volume backup timestamp 和 CNPG collector；健康 peer 不会掩盖单个对象缺指标。它与 **Collection state**、
**Discovery state** 分开：目标抓取失败、目标从服务发现消失、目标仍 up 但关键指标消失，
三种情况不会互相掩盖。**Active platform alerts** 只汇总已经进入 firing 的 #259 与
BEACO-203 规则；它为 0 时仍必须检查前三个证据面板。

## 查询与事件处理

1. **Collection state=Critical**：在 Required targets 找到 `up=0` 的最终 job/instance，
   再看相同 Pod/Service 的 endpoint 与 scrape error。不要先改 selector。
2. **Discovery state=Critical**：查 Ready Pod 与其 ServiceMonitor/PodMonitor selector、
   EndpointSlice 和最终 job label。此状态表示对象仍在运行但没有被 Prometheus 发现。
3. **Metric evidence state=Unknown**：依次执行下列存在性查询，确定缺少的域；如果该域
   的其它实例仍正常，也不能把缺失实例记为健康。

```promql
node_uname_info
kube_node_status_condition{condition="Ready",status="true"}
longhorn_volume_last_backup_at
cnpg_collector_collection_duration_seconds
envoy_server_live
certmanager_certificate_expiration_timestamp_seconds
```

4. **逐卷备份**：按 `pvc_namespace/pvc/volume` 读取
   `(time() - longhorn_volume_last_backup_at) / 3600`，再核对
   `longhorn_backup_state`。每个目标卷都必须有独立的新时间戳；BackupTarget available、
   snapshot 已创建或 Job 成功都不是 completed Backup 的替代证据。
5. **恢复确认**：故障值回到正常后，确认相同 label 集重新出现，相关 firing 告警产生
   resolved，并在至少一个 scrape/evaluation 间隔后再记录恢复。换成新的 target label
   只能视为新目标，不能自动证明原目标恢复。

## 上线、验收与回滚边界

- #259 与本 PR 合并只保存准备文件，不启用任何组件。生产展示前仍需 #259 的
  Prometheus 部署获批并通过 target/rule 验收；Grafana 的提供方式与 datasource 权限也要
  明确批准。
- 若使用临时 Grafana 预览，datasource 只需 Prometheus 查询权限；dashboard 不需要
  Kubernetes、Secret 或 Alertmanager 权限。公开 JSON 不记录私有域名、URL、token。
- 验收至少保存正常、受控故障、无数据、恢复四张截图或等价查询输出，并记录
  datasource、时间窗和 label。离线 fixture 只证明查询语义，不替代现场告警送达。
- 回滚仅删除已导入 dashboard；如果将来做了 provisioning，则撤销那一条父引用并
  reconcile。不要删除 Prometheus/Alertmanager PVC、Secret 或历史告警。存储和通知
  回滚继续使用 `observability-stack.md` 的独立门禁。

OpenStatus 真实入库、三个目标卷的新鲜备份和 20Gi 隔离恢复实读仍是独立验收项；本页
不改变这些结论。
