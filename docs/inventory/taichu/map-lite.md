# MikroTik mAP lite

位于太初机架顶部，连接 RB5009 `ether5`（`auxiliary` 网段），供设备通过无线临时接入太初网络，用于应急维护。型号 `RBmAPL-2nD`，MIPS 24Kc 单核 650 MHz、64 MiB 内存、16 MiB 存储；运行 RouterOS `6.45.9 (long-term)`。

2026-09-23 核验时有线链路为 100 Mbps 全双工。无线由 RB5009 的 CAPsMAN 管理，客户端流量由 mAP lite 本地转发，经 `auxiliary` 网段交给 RB5009 路由。

目前使用独立电源。RB5009 采用 PoE IN 供电时，`ether5` 的 PoE 输出状态为 `no-valid-PSU`，无法通过该口给 mAP lite 供电。

地址与访问状态见私有仓 `infra-private/docs/inventory/taichu/map-lite.md`。
