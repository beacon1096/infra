# DeepSeek V4 Flash Vision 未审查版：Lazycat 应用实现

[AI Pod 应用版本](../aipod-apps.md) ·
[Qwen Image 2.1 Heretic](qwen-image-21-heretic.md)

第二阶段研究记录：不用于生产，目的为了解部署/推理实现与参考性能。
包 ID `cloud.lazycat.aipod.deepseek-v4-flash-vision`，微服本体已装
LPK `0.2.32`（商店已推 `0.2.34`，changelog"提升解码性能"，未升级）。
控制面为 Go 二进制（`deepseek-v4-flash-vision-lpk`），内嵌
`model-host.runtime-model-manifest.v1` 清单。**未部署，无实测性能。**

## 权重清单（0.2.32 内嵌）

| 角色 | 仓库（HF / ModelScope） | 体积 | 文件数 |
| --- | --- | --- | --- |
| target | `s-zaizen/DeepSeek-V4-Flash-Vision-Exp-Abliterated-NVFP4` @ `dfd1defc…` / `manateelazycat/DeepSeek-V4-Flash-Vision-NVFP4-Mirror` @ `f1e6c1db…` | 176.50 GB | 66 |
| inference | 同上（单个小配置文件） | ~0 | 1 |

要点：

- 未审查版走实验性消融仓（`s-zaizen/…-Exp-Abliterated`），ModelScope
  侧为 Lazycat 镜像仓；HF 侧直接用上游仓（与 Qwen Image Heretic 同
  模式，非 Lazycat 重导出）。
- 清单含 `policy user-selected`、`regionProviders`、
  `integrity size-and-sha256`、`cache device-persistent`，与 27B/0.1.83
  一致。

## 运行时与双机拓扑

- 运行时镜像 `registry.lazycat.cloud/catdogai/deepseek-v4-flash-vision:runtime-0.3.1-arm64tls`，
  归档 `deepseek-v4-flash-vision-runtime-0.3.1-arm64.tar`（vLLM
  0.3.1 系）。
- **双机 TP2**：清单与代码中 `tp2` 引用上千处，warm-cache 分
  `…warm-cache-aot-rank0.tar` 与 `rank1.tar` 两份（AOT 编译缓存按
  rank 拆分），部署需两个设备各持一份。
- 服务参数（并发/上下文/KV）需部署后观测；0.2.34 的"提升解码性能"
  未核对（未升级）。
