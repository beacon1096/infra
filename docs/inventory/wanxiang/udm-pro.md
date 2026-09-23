# UDM-Pro

非 NixOS 主路由。

## 硬件信息

| 项目 | 2026-09-23 实机读取 |
| --- | --- |
| 机型 | UniFi Dream Machine Pro（设备自报） |
| CPU | ARM64 4 × Cortex-A57 |
| 内存 | Linux 可见约 3.9 GiB |
| 内置启动介质 | `lsblk` 显示约 14.6 GiB 的 `boot` 块设备，型号字段为 `SD/MMC/MS/MSPRO`；未据此断定可拆卸 SD 卡 |

## 系统

UniFi OS，Debian 11 userland，内核 `4.19.152-ui-alpine`。

## 网络位置

主路由地址 `172.16.80.254`；上游接口 `172.16.20.253/24`。内部网关包括 `172.16.80.254`、`172.16.81.254`、`172.16.84.254`、`172.16.82.254`、`172.16.87.254` 和 `172.16.88.254`。2026-09-23 通过只读 SSH 核验型号为 UniFi Dream Machine Pro、固件为 `5.1.33`；旧清单的上联 `.216` 和固件 `5.1.26` 是过期观察。

## 运行角色

万象网络主路由。
与之交互的 NixOS驻守节点是 [172.16.80.240](./ms-r1.md)

## 访问

SSH 登录方式与现场运维观察见 private 仓 `infra-private/docs/inventory/wanxiang/udm-pro.md`；网关声明配置位于公开仓 `terraform/unifi-wanxiang/`，凭据不在此文档中。
