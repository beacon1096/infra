# 设备库存（总览）

公开仓库按站点记录设备拓扑、可公开的硬件信息和设备角色；运行状态、访问方式及凭据信息见私有仓 `infra-private/docs/inventory/` 对应目录。
私有仓各站点目录正按设备逐步建立；尚未建立的条目仍以现有网络记录为准。

[太初与万象：双集群设计思路](cluster-design.md)

| 站点 | 网段 | 说明 | 私有运维记录 |
| --- | --- | --- | --- |
| [武汉金银潭](jinyintan/) | 172.16.10.0/24 | 独立网络；TrueNAS 备份节点 | 私有仓 `infra-private/docs/inventory/jinyintan/` |
| [武汉光谷](guanggu/) | 172.16.20.0/24 | 主网 + IoT 网 | 私有仓 `infra-private/docs/inventory/guanggu/` |
| [太初](taichu/) | 172.16.100.0/24 | Harvester 集群网络域 | 私有仓 `infra-private/docs/inventory/taichu/` |
| [万象](wanxiang/) | 172.16.80.0/24 | Talos 集群网络域 | 私有仓 `infra-private/docs/inventory/wanxiang/` |
