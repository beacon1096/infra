# Qwen Image 2.1 Heretic：Lazycat 应用实现

[AI Pod 应用版本](../aipod-apps.md) ·
[未审查版 Flash Next](qwen3.8-flash-next.md) ·
[原版 Flash Next](qwen3.8-flash-next-origin.md)

第二阶段研究记录：此类模型不用于生产，目的为了解部署/推理实现与参考
性能。包 ID `cloud.lazycat.aipod.qwen-image-21-heretic`，LPK `0.1.9`。
控制面为 Python 应用（uvicorn，`/app/control/app.py`，清单位于
`/app/manifests/*.json`），可直接读源码——与 Go 二进制内嵌清单的
LLM 应用不同。截至记录日未在算力舱部署，无实测性能。

## 实现概要

- **运行时为 ComfyUI**（Thor 构建 `qwen-image-heretic-thor-0.1.3.tar.gz`，
  5.0 GB，sha256 `606cef4c…`，来自 release CDN
  `registry-static.lazycat.cloud`），导入为
  `registry.lazycat.cloud/catdogai/qwen-image-2.1-heretic-thor:0.1.3`
  （imageId `5f135697…`，另有独立 `configImageId 8db290a4…`）。
  启动参数 `--listen 0.0.0.0 --port 8188 --disable-dynamic-vram`。
- 下载源策略与其余 AI Pod 应用一致：`policy user-selected`、
  `regionProviders {CN: modelscope, default: huggingface}`、
  `integrity size-and-sha256`、`cache device-persistent`；
  ModelScope 各组修订由 `modelscope-lock.json` 钉扎。

## 权重清单（schema qwen-image-heretic.models.v1）

| 组 | 仓库 @ 修订 | 体积 | 内容 |
| --- | --- | --- | --- |
| shared（双源同哈希） | `Comfy-Org/Qwen-Image-2.1` @ `9a44dbdb…` | 7.93 GB | 扩散模型 `qwen_image_2.1_int8_convrot.safetensors`（7.26 GB，INT8 convrot 量化）+ VAE bf16（0.68 GB） |
| 文本编码器 bf16 | `pottokao/Qwen-Image-2.1-Text-Encoder-Heretic` @ `047e5434…` | 17.53 GB | `qwen3vl_8b_bf16_heretic.safetensors` |
| 文本编码器 w4a8（默认） | `…Heretic-W4A8` @ `a124d2d2…` | 6.31 GB | `qwen3vl_8b_w4a8_heretic.safetensors` |
| 文本编码器 nvfp4 | `…Heretic-NVFP4` @ `c50e4a9a…` | 6.31 GB | `qwen3vl_8b_nvfp4_heretic.safetensors` |
| 文本编码器 gguf | `…Heretic-GGUF` @ `23813717…` | 6.19 GB | Q4_K_M（5.03 GB）+ mmproj f16（1.16 GB） |

要点：

- "Heretic" 作用于**文本编码器**（Qwen3-VL-8B，Qwen-Image 的文本条件
  分支）：用 Heretic 消融移除提示词审查，扩散模型本体是 Comfy-Org
  官方 INT8 量化，未改动。安装时 `encoderVariant` 可选
  （w4a8/nvfp4/bf16/gguf），默认 w4a8。
- 双源 URL 直接指向 HF/MS 的 resolve 端点（逐文件同 sha256），运行时
  归档则走 Lazycat release CDN——与 LLM 应用的"双源镜像仓"模式不同，
  这里第三方工件直接用上游仓。
- 全部权重合计约 14–26 GB（取决于编码器变体），远小于 LLM 应用。

## 部署状态与参考性能

未部署。`deploy-models.json` 与 ComfyUI 参数即完整实现依据；图像生成
的参考性能（步数/秒、显存占用）需部署后按工作流测量，或引用厂商页面
（本记录未采集）。
