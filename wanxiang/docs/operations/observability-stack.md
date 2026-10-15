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
- 本地/CI 验收统一使用 `utils/run-observability-test.sh`；脚本解析本仓 flake 的直接
  package aliases，通过
  `flake.lock` 的 nixpkgs revision `aca4d95fce4914b3892661bcb80b8087293536c6`
  固定 Prometheus/promtool `3.12.0`、Alertmanager/amtool `0.31.1`、Helm、kubectl、
  Python 和 PyYAML，不读取调用者的 nixpkgs registry alias。这里的测试工具版本与
  chart 内生产 Prometheus/Alertmanager 镜像分开记账；脚本对实际工具版本做断言。
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
路径。目标 job 使用 Operator v0.90.1 最终 relabel 后的真实值（例如
`monitoring/cnpg-instances`、`longhorn-backend`），而不是内部 scrape config 名称。
Longhorn 固定版本按
[manager v1.12.1 源码](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/metrics_collector/volume_collector.go)
使用 `longhorn_volume_robustness{state="faulted"} == 1`；不沿用旧数值枚举示例。

## 告警覆盖与失败闭合

| 层次 | 信号 | 规则 |
|---|---|---|
| 节点 / 磁盘 | kube-state-metrics、node-exporter | NodeNotReady、可写文件系统余量低于 15%、exporter down/移出发现/逐目标关键指标缺失、两类全域指标缺失 |
| Longhorn | 现有 ServiceMonitor | volume faulted、逐卷从未成功备份、指标缺失；另复用 BEACO-203 的逐卷 stale / failed |
| CNPG | 新增 instance/operator PodMonitor | collector error、复制延迟超过 300 秒、目标 down、关键指标缺失 |
| 网关 | 现有 Envoy PodMonitor | `envoy_server_live < 1`、目标 down、关键指标缺失 |
| 证书 | 现有 cert-manager ServiceMonitor | 14 天内到期、目标 down、到期指标缺失 |

`up == 0`、ready Pod 与 `up` 的逐对象对账、以及关键指标的逐对象 `unless` 分开处理。
其中 kube-state-metrics `2.18.0` 的 `kube_pod_container_status_ready` 使用真实的
container/pod/namespace/uid 标签，不假定不存在的 `condition` 标签。node-exporter 同时覆盖
单目标抓取失败、DaemonSet Pod 仍 Ready 但目标从发现消失，以及 `up=1` 时单目标
`node_uname_info` 丢失：
目标抓取失败、Monitor/selector 把目标移出发现、一个 Longhorn volume 丢失备份时间序列、
或一个 CNPG exporter 丢失 collector 指标，都不能被健康 peer 掩盖。全域 `absent(...)`
仍作为最后一道采集缺失保护。启用后的首轮验收必须先消除或解释所有
`*Missing`，不能通过删除缺失规则取得绿色状态。

## 权限、资源与容量预算

chart 的 Operator 广域 ClusterRole 已关闭，由准备包拆成只读发现与 namespace-local
reconcile 两层，仍复用 chart ServiceAccount：

- cluster-wide `kube-prometheus-stack-operator-discovery` 仅对 ServiceMonitor、PodMonitor、
  PrometheusRule、Probe、ScrapeConfig、AlertmanagerConfig 以及 Nodes/Namespaces 做
  get/list/watch，并只 get StorageClass；没有 Secret/ConfigMap 权限，也没有写权限；
- `monitoring` Role 才能管理本栈 Prometheus/Alertmanager CR、StatefulSet、Service、
  EndpointSlice、生成的 ConfigMap/Secret 和事件。这些写权限不能再按 resourceName
  限定，因为生成对象随 CR reconcile/rollout 变化；verbs 已显式枚举且没有 `*`。
  替代方案是每次升级手工维护所有生成名称，会使升级和故障恢复不可可靠执行，因此
  选择 namespace 边界；
- Operator admission webhook 与内部 TLS 同时关闭；固定 chart 渲染必须显示 HTTP probe、
  HTTP self-monitor 且不挂载 `kube-prometheus-stack-admission` Secret。Operator 管理的
  kubelet Service/Endpoints 及对应 ServiceMonitor 均位于 `monitoring`，复用上述 Role，
  不向 `kube-system` 或 cluster scope 增加写权限；
- kube-state-metrics 只启用 `nodes`、`pods` collectors，渲染 ClusterRole 仅含这两个
  list/watch，不再读取集群 Secret；默认 chart rules 同时关闭，避免为未采集对象产生
  无法求值的规则；
- Prometheus 因跨命名空间 selector，需要读 Services、Endpoints/EndpointSlices、Pods、
  Nodes 与对应 monitoring CR；
- Alertmanager 只选择 `monitoring` 命名空间、标签
  `observability.beacoworks.xyz/alertmanager=wanxiang` 的 AlertmanagerConfig；matcher
  strategy 固定为 `None`，避免 Operator 再注入 `namespace="monitoring"` 导致 storage、
  其它业务 namespace 和无 namespace 的节点告警落入 null。来源限制仍由 namespace +
  label selector 承担，错误 namespace/label 的配置不会被选择。

CI 会实际渲染 chart 并拒绝 KSM Secret 权限、chart 默认 Operator ClusterRole 或自定义
发现 ClusterRole 的 Secret/ConfigMap/写权限回归。不得在 cluster scope 添加 Secret。
2026-10-15 检查的现有 ServiceMonitor/PodMonitor 没有认证 Secret 引用；未来若某个
跨 namespace Monitor 需要认证，必须为那个 namespace/具体 Secret 单独审阅最小 Role，
不能恢复全局 Secret list/watch。
真实 webhook URL/token 只能由 `infra-private` 的 SOPS Secret 与 AlertmanagerConfig
引用，公开仓不保存端点或凭据。

资源请求预算约为：Prometheus 500m/1Gi、Operator 100m/128Mi、Alertmanager
50m/128Mi、kube-state-metrics 50m/128Mi，以及每节点 node-exporter 20m/50Mi。
单副本 Prometheus 保留 7 天且 `retentionSize=15GB`，20Gi PVC；Alertmanager 保留
120 小时，2Gi PVC。两卷均为 `longhorn-r3`，因此逻辑 22Gi 对应最多约 66Gi 原始
副本预算。容量或 series 增长逼近 15GB 时先缩短保留或减少无用 scrape，不能直接
扩大 PVC。

## 离线规则与通知验收

以下测试不访问集群、不发送外部通知；Helm 只拉取固定 chart 做本地渲染：

```bash
bash utils/run-observability-test.sh
```

脚本执行七层检查：

1. 确认 chart digest、selector、保留和 PVC 预算，且父级 Flux 未引用准备包；
2. 实际渲染 chart `83.7.0`，确认 Operator `v0.90.1`、KSM 仅 nodes/pods 权限、chart
   广域 Operator ClusterRole 未生成，自定义 cluster discovery 不含 Secret/写权限；
3. 用 `promtool check rules` 同时解析本包与 BEACO-203 Longhorn 规则；
4. 用 `promtool test rules` 覆盖真实 job/robustness/KSM 标签、正常、故障、目标从发现消失、
   单 node-exporter/volume/CNPG 实例缺指标及恢复，并保留节点、Envoy、证书、备份用例；
5. 用 `amtool config routes test` 验证 storage、其它 namespace、无 namespace 三条路径
   都进入选定路由，而不匹配的 info 对照进入 null；
6. 启动固定版本 Alertmanager 和仅监听 `127.0.0.1` 的临时 webhook stub，实际确认
   三类路径的 `firing` 与 `resolved`，不匹配对照不送达，随后终止进程组并清理。
7. 解析可导入的 `dashboards/wanxiang-platform-overview.json`，确认 Grafana 未启用、
   缺失值显式显示 Unknown，并以实际 panel PromQL 验证正常、故障、无数据和恢复状态。

HelmRelease 的默认 receiver 是无外发配置的 `null`。上述 stub 只存在于测试进程，
不会把测试地址或真实通知目标写进生产配置。

最小仪表盘的导入要求、真实 schema、查询解释、验收证据和独立回滚步骤见
`observability-dashboard.md`。该 JSON 只作为 import artifact 保存，不在本 PR 中启用
Grafana 或 dashboard sidecar。

## 分阶段启用与验收

准备 PR 合并后仍无运行态影响。生产启用需要另一个精确提交和对应批准：

1. 重新渲染 chart `83.7.0`，确认 ClusterRole、镜像、20Gi+2Gi PVC、资源 requests
   与本页一致；确认 Longhorn 至少还有 66Gi 原始可调度余量。
2. 审阅 `infra-private` 的
   `wanxiang/kubernetes/apps/monitoring/alertmanager-config/app/alertmanagerconfig.yaml`。
   该未引用模板位于 `monitoring` 且带上述 selector label；route 不添加 namespace
   matcher，按 severity/alertname 分组，webhook URL 与 token 仅引用同 namespace Secret。
   私有 harness 从该模板派生实际 Alertmanager 路由，并只向 loopback stub 验证
   firing/resolved。真实 Secret、渠道和父级引用仍必须另行批准。
3. 只在获批提交中，把 `./prometheus-stack/ks.yaml` 加到
   `kubernetes/apps/monitoring/kustomization.yaml`。确认同环境无并发 Flux/存储变更，
   再 reconcile。
4. 验收 Prometheus/Alertmanager/Operator Ready、PVC Bound、所有预期 targets up、
   `longhorn-backup` 与 `wanxiang-platform-health` 成功加载且无 rule evaluation error。
5. 先用合成 alert 对获批渠道验证 firing/resolved；再选择不会损坏业务的一个受控
   目标失败/恢复。逐卷备份新鲜度必须查看每个 volume 的时间序列，不能以 Job
   succeeded、BackupTarget available 或其它卷健康代替。

停止条件：出现 cluster-wide Secret/ConfigMap 权限、非 monitoring 命名空间写入、PVC
预算变化、Prometheus 超过 2Gi 内存、存储逼近 15GB、预期 target/metric 缺失或通知
指向非批准端点时，停止启用并保持/恢复父级不引用本目录。

## 回滚

1. 移除父级对 `./prometheus-stack/ks.yaml` 的引用并 reconcile；不要先手工删除 CR。
2. 确认 Prometheus/Alertmanager/Operator、Service 与新增 CNPG PodMonitor/规则已由
   Flux 清理，原有 Longhorn、Envoy、cert-manager Monitor/Rule 保持不变。
3. 保留 Prometheus 20Gi 与 Alertmanager 2Gi PVC 供复盘；删除 PVC 属存储操作，需
   单独批准。回滚期间不删除业务指标源、Longhorn Backup 或告警历史证据。
