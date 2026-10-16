# Prometheus 与 VictoriaMetrics 隔离实测

本页记录 BEACO-229 在 2026-10-16 的五分钟隔离实测。结论是：**当前保留
Prometheus**。VictoriaMetrics 在本短测中减少了磁盘增长，但完整 VM 路径没有降低
CPU 或内存，且多出 vmagent、vmalert 和默认约 30 秒查询可见性偏移；五分钟测试没有
跨过压缩或保留周期，不能把短测磁盘差异解释为长期节省。

仓库内 `utils/metrics-backend-benchmark/results/2026-10-16/` 仅保留生成的公开配置、
校验结果、汇总和元数据；复现入口与边界见
`utils/metrics-backend-benchmark/README.md`。包含逐条采样、完整快照和脱敏进程日志的原始
22 文件不进入 Git，作为 [BEACO-216 附件](https://multica.beaco.works/uploads/workspaces/143a067c-ff0d-420a-8c6a-497c4786c747/01a1446c-f8f3-701e-91ce-1399eade5308.gz)
归档；精简目录保留 10 个文件、35,837 bytes。归档为 103,507 bytes，SHA-256
`61e3e5ee5c4db4aa998896a041832862fab073d361ee79b95b50eb2426a491a5`。归档中的 22 个文件
已逐一与旧提交 `2b44c2ed6155b8d3ab22cbd19729b25a162ce54d`（tree
`266650d3d80da35becd2c5c4bf84aa129167a8e0`）的 Git blob 核对一致。材料只含合成数据、
脱敏日志和公开规则；私有通知模板按固定提交读取和校验；派生配置仅短暂写入结果树之外
的临时目录，并在成功、失败或中断时删除，没有复制到本仓。

## 口径与边界

- 硬件：Intel Core i9-12900H，Linux 6.18.48-talos；运行容器可见 20 个 CPU、
  8 GiB cgroup 内存，底层 ext4。
- 版本：Prometheus 3.12.0；VictoriaMetrics Single、vmagent、vmalert 1.146.0；
  两边均使用 Alertmanager 0.31.1。版本由本仓 `flake.lock` 固定。
- 输入：5,000 条稳定 `synthetic_load_value`、1,000 条每 30 秒换 label 的 churn
  序列，并为 churn 生成 1,000 条 counter；另有实际规则所需的脱敏域指标。
  两边配置相同的十个 target，5 秒 scrape/evaluation、1 天 retention。
- 查询：实际 dashboard 的 14 条 PromQL，每 10 秒对两边各执行一次，共各 420 次；
  保留 11 条 instant 与 3 条 range target 的 Grafana 模式，range 使用共同五分钟窗口和
  5 秒 step。故障窗覆盖指标缺失、Longhorn 陈旧/失败/故障和恢复。
- 资源预算：每栈独立 2 CPU affinity、1.5 GiB 聚合 RSS、2 GiB 数据目录；
  超限即中止，外层 wall time 最多 60 分钟。本次没有触发上限。
- Prometheus 栈计入 Prometheus + Alertmanager；VM 栈计入 VMSingle + vmagent +
  vmalert + 同版 Alertmanager。合成 exporter 和查询驱动是共同输入，均不计入。
  kube-state-metrics、node-exporter 和业务 exporter 也是两方案共同组件，未在本地启动。
  Prometheus Operator 与 VM Operator 都未计入；因此不能用本结果宣称完整 chart 的
  controller 开销已测量。
- 21 条实际规则的表达式、label 和 annotation 保持不变，但所有 `for` 缩短到 15 秒；
  私有通知路由的分组等待在隔离接收端缩短为 0/1 秒。生产等待时间没有在本轮验证。

## 结果

| 指标（整栈） | Prometheus | VictoriaMetrics | 解释 |
|---|---:|---:|---|
| CPU 平均 | 0.00659 core | 0.02271 core | VM 约 3.45 倍，但两者绝对值都很低 |
| CPU 采样峰值 | 0.050 core | 0.210 core | VM 包含三个指标进程 |
| RSS 平均 | 162.2 MiB | 185.1 MiB | VM 高 14.1% |
| RSS 峰值 | 176.5 MiB | 205.2 MiB | VM 高 16.2% |
| 数据/WAL/队列增长 | 2.76 MiB | 1.55 MiB | VM 低 43.7%；仅是压缩周期前短测 |
| 实际 dashboard 查询 p50 | 0.510 ms | 0.506 ms | 同量级 |
| 实际 dashboard 查询 p95 | 1.284 ms | 1.400 ms | 同量级 |
| 查询失败 | 0 / 420 | 0 / 420 | 两边均通过 |

VM 的 1.55 MiB 包含 VMSingle、vmagent 队列、vmalert 和 Alertmanager；Prometheus 的
2.76 MiB 包含 Prometheus 与 Alertmanager。这里统计运行期数据目录的逻辑文件字节，
不包含进程退出时才可能持久化的 cache。短测没有触发 TSDB block compaction，也没有
跨过一天 retention，故不能外推七天生产占用或供应商宣传的压缩倍数。

数据完整性终检使用共同的历史 evaluation time（避开 VM 默认偏移），两边都有 6,000
条活跃 `synthetic_load_value`，最近两分钟都返回 144,000 个样本。另以客户端墙钟减去
返回的最新 sample timestamp：Prometheus 为 0.41 秒，VM 为 34.18 秒；后者包含默认
30 秒查询偏移，不能解释成 0–5 秒新鲜度。引擎总计数不是同一口径：Prometheus head
appended 为 435,774，VMSingle inserted 为 444,136，后者还包含 vmalert 写回；vmagent
scraped 为 421,482、pushed 为 443,683。这里以同一业务 metric 的共同时间 count/range
结果作为完整性结论，不拿不同自监控计数直接算丢失率。

## 规则、查询与通知兼容性

- promtool 与 vmalert 都实际加载了同一份 21 条规则；14 条 dashboard target（含 3 条
  range matrix）在两边均无错误。五分钟 range 窗口在测试前段包含进程启动边界，VM
  比 Prometheus 多 1–2 个前导点；shape differences 和原始 matrix 均已保留，故本轮
  不宣称 range 响应逐点等价；故障/恢复边界的共同时间点也有默认偏移造成的值差异。
  恢复后的 instant 快照同样保留了 VM 默认偏移导致的故障旧值，这属于下一条所述的
  可见性差异。当前实际表达式中没有 `rate`、`irate` 或 `increase`，因此本轮没有适用的
  counter 外推差异可比较。
- `WanxiangNodeExporterMetricMissing`、`LonghornBackupStale`、
  `WanxiangLonghornVolumeFaulted`、`LonghornBackupFailed` 在两种引擎上均通过真实
  firing 与 resolved，并由同版 Alertmanager 送到隔离 loopback。VM 的首次通知比
  Prometheus 晚约 31–37 秒；45 秒预热后的健康基线和最终恢复窗口均无 firing。
  没有真实业务通知。
- 恢复后约 30 秒内，VM dashboard 仍返回故障期值；稍后的快照与终检恢复一致。这与
  VictoriaMetrics 默认 `-search.latencyOffset=30s` 相符：官方说明该偏移为了避免当前
  scrape interval 的不完整结果，也可按查询覆盖。vmalert 文档同时说明默认
  `-rule.evalDelay=30s` 用于补偿该延迟。若以后选择 VM，应明确接受这段观测延迟，或在
  独立验收不完整点风险后再调小，不能把它当作丢样本或直接设为零。
- 20 秒 vmagent→VMSingle 断链产生 12 次 503，持久队列写入并读回 162,111 bytes，
  dropped=0、最终 pending=0；断链后最终样本数与 Prometheus 对齐，VM 墙钟新鲜度回到
  上述默认偏移的预期边界内。

VictoriaMetrics 查询延迟说明：
[Key concepts / Query latency](https://docs.victoriametrics.com/victoriametrics/keyconcepts/#query-latency)；
vmalert 延迟说明：
[vmalert / Data delay](https://docs.victoriametrics.com/vmalert/#data-delay)。

## Operator 接入与删除语义

本轮没有搭建 VM Operator。官方兼容层可以把现有 `ServiceMonitor`、`PodMonitor`、
`PrometheusRule` 分别转换为 `VMServiceScrape`、`VMPodScrape`、`VMRule`，并同步更新；
Prometheus CRD 仍需另行安装。默认删除原 Prometheus 对象时**不会**删除转换对象，便于
双栈迁移，但会与本仓期望的 GitOps 删除同步不同。若未来采用 VM Operator，应显式启用
converter ownership，让 Kubernetes ownerReference 同步删除，并先在一次性 namespace
验证创建、更新、删除和 selector 范围；不能只证明转换创建成功。

来源：
[VictoriaMetrics Operator 的 Prometheus 兼容与删除同步](https://docs.victoriametrics.com/operator/integrations/prometheus/)。

## 决策与后续门槛

当前证据支持保留已准备的 Prometheus 方案：它的进程链更短，本轮 CPU/内存更低，实际
查询与告警全部通过；VM 的短期磁盘优势不足以抵消新增组件、默认可见性延迟和转换删除
策略。该结论只针对当前小型 homelab 与本次负载，不是通用性能排名。

仅当实际七天容量或 Prometheus 内存成为约束时再重开 VM 选择。届时应另行限定并批准
跨过一次 TSDB compaction 的隔离测试，保持相同业务 series/churn/query、计入两边
operator，并用 cgroup/容器或等效方式实际施加 CPU 与内存硬限额；本轮累计授权仍以最多
两小时为界，不授权 24 小时运行。
生产 Flux、PVC、Secret、真实通知和现有审批策略本轮均未修改；无 suspend/resume，回滚
仅需丢弃本准备分支。备份不适用，因为没有生产或持久卷写入。
