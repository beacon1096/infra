# Prometheus 与 Alertmanager 准备包

本页是 BEACO-216 的上线前材料，不是生产部署记录。目录
`kubernetes/apps/monitoring/prometheus-stack/` 已具备可渲染的 Flux
`Kustomization`，但父级 `monitoring/kustomization.yaml` **没有引用它**；合并本准备
PR 不会创建 Pod、PVC、Secret、RBAC 或通知，也不会改变现有 Flux 对象。

## 固定版本与现有采集入口

- `kube-prometheus-stack` 固定为 chart `83.7.0`，OCI artifact 固定为
  `sha256:ae5cd17378e9da8820fd3ea55ddfbd4bdd4d0c61f3b5bb4e04bb288b00f95f87`。
  bootstrap 已从同版本安装 Prometheus Operator CRD，HelmRelease 明确跳过 CRD
  install/upgrade。
- 离线验收工具由本仓 `flake.lock` 固定：Prometheus/promtool `3.15.0`、
  Alertmanager `0.33.1`。
- Prometheus 设置
  `serviceMonitorSelectorNilUsesHelmValues: false`、
  `podMonitorSelectorNilUsesHelmValues: false`、
  `ruleSelectorNilUsesHelmValues: false`，配合空 selector/namespace selector，接入所有
  命名空间现有的 ServiceMonitor、PodMonitor 和 PrometheusRule。
- 2026-10-15 的只读清单确认关键现有对象为 Longhorn
  `ServiceMonitor/longhorn-prometheus-servicemonitor`、Envoy
  `PodMonitor/envoy-proxy`、cert-manager `ServiceMonitor/cert-manager` 和 BEACO-203
  `PrometheusRule/longhorn-backup`。准备包补充 CNPG instance/operator PodMonitor；
  CNPG Pod 实际暴露 `metrics` 端口。

这意味着 BEACO-203 的 `LonghornBackupStale` / `LonghornBackupFailed` 会被直接复用，
而不是复制成另一套规则。补充规则覆盖从未成功备份的卷、关键指标缺失和其它平台
路径。`longhorn_volume_robustness == 3` 的 faulted 判定沿用
[Longhorn 1.12.1 官方规则示例](https://longhorn.io/docs/1.12.1/monitoring/alert-rules-example/)。

## 告警覆盖与失败闭合

| 层次 | 信号 | 规则 |
|---|---|---|
| 节点 / 磁盘 | kube-state-metrics、node-exporter | NodeNotReady、可写文件系统余量低于 15%、两类指标缺失 |
| Longhorn | 现有 ServiceMonitor | volume faulted、逐卷从未成功备份、指标缺失；另复用 BEACO-203 的逐卷 stale / failed |
| CNPG | 新增 instance/operator PodMonitor | collector error、复制延迟超过 300 秒、目标 down、关键指标缺失 |
| 网关 | 现有 Envoy PodMonitor | `envoy_server_live < 1`、目标 down、关键指标缺失 |
| 证书 | 现有 cert-manager ServiceMonitor | 14 天内到期、目标 down、到期指标缺失 |

`up == 0` 与各域 `absent(...)` 分开处理：目标存在但抓取失败、Monitor/selector
根本没有产生目标、exporter 在线但关键指标消失，都不能显示健康。启用后的首轮验收
必须先消除或解释所有 `*MetricsMissing`，不能通过删除 absent 规则取得绿色状态。

## 权限、资源与容量预算

chart 自带 RBAC，准备包不添加自定义高权限 ServiceAccount：

- Prometheus Operator 需要 cluster-wide list/watch PrometheusRule、ServiceMonitor、
  PodMonitor、Probe、Prometheus、Alertmanager 及其生成的工作负载；
- Prometheus 因跨命名空间 selector，需要读 Services、Endpoints/EndpointSlices、Pods、
  Nodes 与对应 monitoring CR；
- Alertmanager 只选择 `monitoring` 命名空间、标签
  `observability.beacoworks.xyz/alertmanager=wanxiang` 的 AlertmanagerConfig。

上线前必须审阅 chart 渲染出的 ClusterRole；不得再授予 Secret 的通配读权限。
真实 webhook URL/token 只能由 `infra-private` 的 SOPS Secret 与 AlertmanagerConfig
引用，公开仓不保存端点或凭据。

资源请求预算约为：Prometheus 500m/1Gi、Operator 100m/128Mi、Alertmanager
50m/128Mi、kube-state-metrics 50m/128Mi，以及每节点 node-exporter 20m/50Mi。
单副本 Prometheus 保留 7 天且 `retentionSize=15GB`，20Gi PVC；Alertmanager 保留
120 小时，2Gi PVC。两卷均为 `longhorn-r3`，因此逻辑 22Gi 对应最多约 66Gi 原始
副本预算。容量或 series 增长逼近 15GB 时先缩短保留或减少无用 scrape，不能直接
扩大 PVC。

## 离线规则与通知验收

以下测试不访问集群、不发送外部通知：

```bash
nix-shell -I nixpkgs=flake:nixpkgs \
  -p prometheus.cli prometheus-alertmanager kubectl \
  'python3.withPackages (ps: [ ps.pyyaml ])' \
  --run 'python3 utils/test-observability-prep.py'
```

脚本执行四层检查：

1. 确认 chart digest、selector、保留和 PVC 预算，且父级 Flux 未引用准备包；
2. 用 `promtool check rules` 同时解析本包与 BEACO-203 Longhorn 规则；
3. 用 `promtool test rules` 注入目标 down、节点异常、CNPG collector error/指标缺失、
   Envoy 不可用、逐卷无备份和证书即将到期，并确认各自恢复后 alert 清除；
4. 启动固定版本 Alertmanager 和仅监听 `127.0.0.1` 的临时 webhook stub，确认实际
   收到 `firing` 与 `resolved`，随后终止进程组并删除临时数据。

HelmRelease 的默认 receiver 是无外发配置的 `null`。上述 stub 只存在于测试进程，
不会把测试地址或真实通知目标写进生产配置。

## 分阶段启用与验收

准备 PR 合并后仍无运行态影响。生产启用需要另一个精确提交和对应批准：

1. 重新渲染 chart `83.7.0`，确认 ClusterRole、镜像、20Gi+2Gi PVC、资源 requests
   与本页一致；确认 Longhorn 至少还有 66Gi 原始可调度余量。
2. 在 `infra-private` 准备带上述 selector label 的 AlertmanagerConfig；webhook URL
   与 token 使用 SOPS Secret 引用。默认 `null` receiver 可先完成纯求值验收，真实
   渠道必须另行批准。
3. 只在获批提交中，把 `./prometheus-stack/ks.yaml` 加到
   `kubernetes/apps/monitoring/kustomization.yaml`。确认同环境无并发 Flux/存储变更，
   再 reconcile。
4. 验收 Prometheus/Alertmanager/Operator Ready、PVC Bound、所有预期 targets up、
   `longhorn-backup` 与 `wanxiang-platform-health` 成功加载且无 rule evaluation error。
5. 先用合成 alert 对获批渠道验证 firing/resolved；再选择不会损坏业务的一个受控
   目标失败/恢复。逐卷备份新鲜度必须查看每个 volume 的时间序列，不能以 Job
   succeeded、BackupTarget available 或其它卷健康代替。

停止条件：出现未审阅 ClusterRole/Secret 读取、非 monitoring 命名空间写入、PVC
预算变化、Prometheus 超过 2Gi 内存、存储逼近 15GB、预期 target/metric 缺失或通知
指向非批准端点时，停止启用并保持/恢复父级不引用本目录。

## 回滚

1. 移除父级对 `./prometheus-stack/ks.yaml` 的引用并 reconcile；不要先手工删除 CR。
2. 确认 Prometheus/Alertmanager/Operator、Service 与新增 CNPG PodMonitor/规则已由
   Flux 清理，原有 Longhorn、Envoy、cert-manager Monitor/Rule 保持不变。
3. 保留 Prometheus 20Gi 与 Alertmanager 2Gi PVC 供复盘；删除 PVC 属存储操作，需
   单独批准。回滚期间不删除业务指标源、Longhorn Backup 或告警历史证据。
