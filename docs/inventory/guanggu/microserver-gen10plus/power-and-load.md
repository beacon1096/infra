# GPU 持续负载与供电（MicroServer Gen10 Plus）

设备信息见 [设备记录](./readme.md)；实验背景见 [Strata + Swift 1.5 实验记录](./strata-experiment.md)。

A2000 在这台 MicroServer Gen10 Plus 上做持续负载（推理或长时间游戏）会触发主板供电故障并断电。以下为 2026-09-28 的观测。

## 现象

- iLO 报 Critical：`Runtime Fault, System Board, P12V Main/AUX Regulators (10h)`，整机随即断电。
- 断电后状态：`PowerState: Off`、`State: Disabled`；`AggregateServerHealth=Critical`，其中 `BiosOrHardwareHealth=Critical`，而 Fans / Memory / Network / PowerSupplies / Processors / Storage / Temperatures 全部 OK，iLO 自身 `Health=OK`。
- 重启后 iLO 健康恢复 OK，IML 仍保留该条历史故障（`Repaired=false`），之后未再复现。

## 时间线（CST，UTC+8）

| 时间 | 事件 |
| --- | --- |
| 04:02:02 | 首次 API 冒烟测试成功（模型已完成加载） |
| 04:10:07 | 经 Tailscale 的一次对话请求成功返回 |
| ~04:11:5x | 在 Web UI 提了一个问题 |
| 04:11:54 | iLO IML 记录 Critical：P12V Main/AUX Regulators (10h) |
| 04:11:57 | iLO `Embedded Flash: Restarted` |
| 04:12:04 | `Server power removed`（整机断电） |
| 04:16:43 | 用户登录 iLO，随后打开远程控制台 |
| 04:23:30 | 手动开机，`Server power restored` |
| 04:30:18 | 开机后 iLO 警告：Slot 1（GPU）OS 驱动缺失，电源传感器未知 |

从故障到断电约 10 秒；从最后一次成功生成到故障约 1 分 47 秒。这与「先在 Web UI 提问、随后整机立即断电」的现场观察一致——模型常驻本身不等于安全，触发点落在一次请求期间。

## 电源与供电

- 原装 HP DC 圆孔外置电源只有 200 W；已按网络方案更换 Alienware 300 W，故障仍出现。
- 结论：限制不止于电源额定功率，**主板 12V 主/辅稳压（VRM）供电链路本身更可能是瓶颈**。
- 用户经验：A2000 长时间打游戏同样会触发（并非本实验特有）；此前用 vLLM 跑 GLM-7B 一类模型、只有 webchat、且都是短请求，未出现问题。
- 方向性判断（未经仪器测量）：Strata 同时压榨 GPU、CPU 与 SSD（RAM 常驻 experts、CPU 计算未驻留 experts、SSD 流式读取 n-gram 表），比短请求 webchat 更接近持续满载，因而更容易触发。

## 遥测缺口

- **Active Health System 未开启**：iLO `ActiveHealthSystem` 报 `AHSEnabled=false`（`SoftwareEnabled=false`），故障窗口没有详细遥测。
- **本机无功耗计量**：`HasPowerMetering`、`HasGpuPowerMetering`、`HasCpuPowerMetering`、`HasDimmPowerMetering` 全为 `false`，`PowerMetric` 各项为 `null`；`BrownoutRecoveryEnabled=true`。
- GPU（Slot 1）电源/温度传感器对 iLO 不可见（`09-GPU 1` 读数为 0、状态为空；见时间线 04:30 警告）。
- 因此无法量化故障瞬间的功耗/温度。iLO 建议收集 AHS 日志并开 HPE support case，但当前 AHS 处于关闭状态。

## 其他子系统

- 阵列：`md127` RAID5 全程 `[3/3] [UUU]` 健康，未参与故障。
- `dmesg` 无 MCE / EDAC 错误。故障不在磁盘、内存或温度；CPU 温度正常（重启后约 40 °C）。

## 结论

本机目前无法用于稳定可靠的高性能或长时间推理（A2000 持续负载会触发主板供电故障）。若要继续使用 A2000，需要先解决主板供电（VRM），并考虑开启 AHS 以留下遥测；在此之前不建议跑持续满载负载。
