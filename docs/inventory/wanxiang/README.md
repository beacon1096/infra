# 万象（wanxiang）· 172.16.80.0/24

原 `talos-ii`，Talos 集群 `kubernetes`（172.16.87.0/24，API VIP `172.16.87.1:6443`）。
网关 UDM-Pro，上游接入光谷 `172.16.20.0/24`。
集群结构化记录见公开仓 `wanxiang/inventory.yaml`。

## 机柜（Ubiquiti 免工具机柜，从上至下）

1. UAP-AC-Lite
2. UDM-Pro（主路由）
3. USW-Aggregation（8×10G SFP 交换机）
4. 设备组（左右）：`ms01-a` / `ms-r1`
5. 设备组（左右）：`ms01-b` / `ms01-c`

## 设备（2026-09-23 实机复核）

- [UDM-Pro 主路由](udm-pro.md)
- [ms-r1 LAN 镜像节点](ms-r1.md)
- [ms01-a Talos 节点](ms01-a.md)
- [ms01-b Talos 节点](ms01-b.md)
- [ms01-c Talos 节点](ms01-c.md)
- [UAP-AC-Lite 与 USW-Aggregation](switching-and-wifi.md)

三台 Talos 节点现均为 Ready、可调度，运行 Talos `v1.13.10` / Kubernetes `v1.36.4`；此前 `ms01-c` cordon 和旧版本的观察已过时。逐台硬件及历史记录见 [结构化清单](../../wanxiang/inventory.yaml)与各设备文档。
