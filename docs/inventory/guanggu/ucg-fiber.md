# UCG-Fiber

主路由；地址 `172.16.20.254`。UniFi OS 设备。

## 硬件信息

| 项目 | 观察值 |
| --- | --- |
| CPU | Qualcomm IPQ9574，4 核 |
| 内存 | 2.8 GiB |
| 系统存储 | 14.6 GB EMMC |
| 监控存储 | 256 GB NVMe |

## 系统

UniFi OS，Debian 11 userland，内核 `5.4.213-ui-ipq9574`，aarch64。

## 网络位置

- 主网网关 `172.16.20.254/24`
- IoT 网关 `172.16.22.254/24`
- 上游
  - ISP 武汉电信
  - 网段 `192.168.1.x/24` (DHCP)

## 运行角色

光谷主路由，提供主网和 IoT 网关。
与之交互的 NixOS驻守节点是 [172.16.20.11](./microserver-gen10plus.md)

## 访问

SSH 登录信息、凭据、DNS Shield 和 SNAT 细节见 private 仓 `infra-private/docs/inventory/guanggu/ucg-fiber.md`。
