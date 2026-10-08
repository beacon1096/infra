# GLM 5.3 Flash：Lazycat 应用实现

[AI Pod 应用版本](../aipod-apps.md) ·
[DeepSeek V4 Flash Vision](deepseek-v4-flash-vision.md)

第二阶段研究记录：不用于生产，目的为了解部署/推理实现与参考性能。
包 ID `cloud.lazycat.aipod.glm53f`，微服本体现装 LPK `0.3.15`（商店当前
无更新）。控制面为 Go 二进制（`glm53f-lpk`），内嵌
`model-host.runtime-model-manifest.v1` 清单。**未部署，无实测性能。**

## 权重清单（0.3.15 内嵌）

| 角色 | 仓库（HF / ModelScope） | 体积 | 文件数 |
| --- | --- | --- | --- |
| target | `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw`（两源同仓）@ `024db9f7…`（HF）/ `8750c31f…`（MS） | 175.72 GB | 129 |
| draft | `incoai/GLM-5.3-Flash-DFlash2` @ `dc77ff1c…`（HF）/ `83a5c8ec…`（MS） | 2.34 GB | 2 |

要点：

- 主体量化为 **EXL3 4bpw（TR3）**——Lazycat AI Pod 应用中首个 EXL3
  路线（其余均为 ModelOpt NVFP4/FP8 系）；129 个分片。
- DFlash2 草稿与 Flash Next 同族（`incoai/GLM-5.3-Flash-DFlash2`，
  另有 `manateelazycat/GLM-5.3-Flash-DFlash2` 镜像仓在组织清单中）。
- 清单策略字段与 27B/0.1.83 一致（user-selected、regionProviders、
  size-and-sha256、device-persistent）。

## 运行时与双机拓扑

- 运行时镜像 `registry.lazycat.cloud/catdogai/glm53f:runtime-0.3.13-arm64`，
  归档 `glm-5.3-flash-dual-t5000-runtime-0.3.13.tar`——**归档名即标明
  dual-t5000**。
- **双机 TP2**：`tp2` 引用上千处；相关组织仓还有
  `manateelazycat/GLM-5.3-Flash-TensorFold-Runtime` /
  `GLM-5.3-Flash-EXL3-TensorFold`（TensorFold 为其跨机张量折叠方案）。
- 服务参数需部署后观测。
