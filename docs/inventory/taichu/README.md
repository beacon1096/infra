# 太初（taichu）· 172.16.100.0/24

Harvester 集群（`mc5-01`/`mc4-01`/`mc4-02`）、RB5009 路由和 m920x 驻守节点。
上游经 `inbound` 接入光谷 `172.16.20.0/24`（`172.16.20.252/24`）。
管理网、虚拟机网、Rancher 网和存储网分别为 `172.16.100.0/24`、`172.16.101.0/24`、`172.16.102.0/24` 和 `172.16.105.0/24`；RB5009 在这些网段均使用 `.254`。
三台 NEC 的存储口接在同一台 2.5GbE 交换机上；该交换机上联 RB5009 `ether3`，m920x 接管理网 `ether4`。Harvester 的 Longhorn 存储地址由 Whereabouts 分配，RB5009 的存储网 DHCP 已关闭。
[`taichu/inventory.yaml`](../../../taichu/inventory.yaml) 是 2026-08-13 的历史采集快照，其中的地址和运行状态不代表当前状态。

## 机架（3D 打印机架，从上至下）

以下顺序来自 2026-09-13 的用户描述与端口对应记录，尚未现场复核；交换机型号待确认。

1. [mAP lite](map-lite.md)（目前单独供电）
2. 2.5GbE 交换机
3. [RB5009UPr+S+](rb5009.md)
4. [ThinkCentre m920x](m920x.md)
5. [NEC Mate MC-4 `mc4-02`](mc4-02.md)
6. [NEC Mate MC-4 `mc4-01`](mc4-01.md)
7. [NEC Mate MC-5 `mc5-01`](mc5-01.md)

从上往下三台 NEC 的管理网线分别接 RB5009 `ether8`、`ether7`、`ether6`。

## 设备（2026-09-23 实机核验）

- [RB5009UPr+S+ 主路由](rb5009.md)
- [mAP lite](map-lite.md)
- [ThinkCentre m920x 驻守节点](m920x.md)
- [Harvester 节点 mc5-01](mc5-01.md)
- [Harvester 节点 mc4-01](mc4-01.md)
- [Harvester 节点 mc4-02](mc4-02.md)

## 集群状态（2026-09-23）

三台 Harvester 节点均为 `Ready`，运行 Harvester v1.7.1。采集时可见运行中的 Keycloak 和三台配置为 Nix 构建机与 Forgejo runner 的 `nixbuilder` 虚拟机。

Longhorn 存在降级卷；备份目标与恢复路径仍需核验。访问方式、本次运行状态及 RB5009 的历史评审项见私有仓 `infra-private/docs/inventory/taichu/`。
