# 懒猫微服上的 AI Pod 应用版本

[懒猫微服本体](../lazycat-microserver.md) ·
[AI Pod 设备记录](../lazycat-aipod/README.md)

记录日期：2026-10-02。AI Pod 相关的 Lazycat 应用（LPK）先由微服本体接收更新，
AI Pod 再从中拉取；本文记录微服本体上已缓存的 LPK 版本，作为 AI Pod 应用
更新的上游参照。版本读取自本体的包管理目录（`pkgm` 下各应用的
`package.yml` 与 `manifest.yml`）。

基线为 [Thor 推理文档](../../../inference/thor/README.md)的 2026-09-18 快照。

## AI Pod 模型应用

| 包 ID | 应用 | 基线 LPK | 当前 LPK |
| --- | --- | --- | --- |
| `cloud.lazycat.aipod.qwen38-flash-next` | Qwen 3.8 Flash Next 未审查版 | `0.1.40` | `0.1.48` |
| `cloud.lazycat.aipod.qwen38-flash-next-origin` | Qwen 3.8 Flash Next 原版 | 无此包（基线后新增） | `0.2.6` |
| `cloud.lazycat.aipod.qwen38-27b` | Qwen 3.8 27B 未审查版 | `0.1.58` | `0.1.79` |
| `cloud.lazycat.aipod.deepseek-v4-flash-vision` | | — | `0.2.32` |
| `cloud.lazycat.aipod.glm53f` | | — | `0.3.15` |
| `cloud.lazycat.aipod.minimax-h3` | | — | `0.4.9` |
| `cloud.lazycat.aipod.deepseek-ocr-2` | | — | `2.0.3` |
| `cloud.lazycat.aipod.paddleocr-vl` | PaddleOCR VL | — | `1.5.0` |
| `cloud.lazycat.aipod.pp-ocrv6` | | — | `0.2.7` |
| `cloud.lazycat.aipod.qwen-image-21-heretic` | | — | `0.1.9` |
| `cloud.lazycat.aipod.gpt-sovits` | | — | `0.4.0` |
| `cloud.lazycat.aipod.hy-mt2` | | — | `0.1.15` |
| `cloud.lazycat.aipod.indextts` | | — | `2.0.1` |
| `cloud.lazycat.aipod.r2t2` | | — | `0.1.7` |
| `cloud.lazycat.aipod.voxcpm` | | — | `2.0.0` |
| `cloud.lazycat.aipod.whisper` | | — | `0.2.0` |

其余非 AI Pod 专属应用的版本不在本文记录范围。

## 观察

- 两个 Qwen3.8 模型应用的 LPK 在基线后均有多版更新（Flash Next +8、
  27B +21）。2026-10-02，`qwen38-27b` 已以 LPK `0.1.79` 重部署至 AI Pod：
  运行时镜像换为 `runtime-104-0.3.1-model-split`，权重改为从 ModelScope
  镜像仓（组织 `manateelazycat`）逐文件下载、网盘暂存并校验后传入算力舱，
  详见 [27B 部署记录](thor-apps/qwen3.8-27b.md)。
- 同日，`qwen38-flash-next` 以模型制品 `0.1.8` 重部署（LPK 仍为 `0.1.48`）：
  运行时镜像 `runtime-124-0.1.8`，分发同为 ModelScope 镜像仓加 aria2 下载、
  网盘中转，包内携带消融工具链；两处精度修复（GDN 状态 FP32、BF16
  lm_head）与 KV 容量代价详见 [Flash Next 部署记录](thor-apps/qwen3.8-flash-next.md)。
- `qwen38-flash-next-origin` 是基线快照后新出现的包，与"未审查版"
  并存；两者的运行时镜像与配置差异待核对。

原始清单通过 `lpk-manager list` 与包管理目录核对，未做全盘扫描。
