# Qwen 3.8 Flash Next（原版）：Lazycat 应用部署

[未审查版部署记录](qwen3.8-flash-next.md) ·
[AI Pod 应用版本](../aipod-apps.md)

原版（未消融）应用，包 ID `cloud.lazycat.aipod.qwen38-flash-next-origin`，
商店描述定位为"日常生产力"用途。2026-10-03 记录。本文数据来自已安装
LPK 控制面二进制的内嵌清单（`model-host.runtime-model-manifest.v1`，
完整性策略 `size-and-sha256`），未实际部署、无下载流量。

## 已安装版本与权重清单

- 2026-10-02 起 LPK `0.2.6`，同日商店推 `0.2.8`（恢复并核验原版在
  HF/MS 的运行归档）后已升级；两者权重与运行时完全一致，差异仅为
  分发核验逻辑（控制面镜像 `886eb651…` → `b8cd6fd8…`，二进制重建）。

权重清单（LPK 0.2.8 内嵌）：

| 角色 | 仓库（HF / ModelScope） | 体积 | 内容 |
| --- | --- | --- | --- |
| target | `RadixArk/Qwen3.8-Flash-Next-NVFP4` @ `7b719225…`（HF）/ `a6cc3dfc…`（MS） | 131.71 GB，217 文件 | 48 层 × 4 专家组分片（`layer-XXXXX-experts-NNNN-NNNN.safetensors`，各约 354 MB）、`model-bf16-00001/00010/00011/00012.safetensors`、`model-plefp8-00000..00009.safetensors`、config/tokenizer/vocab/merges、`preprocessor_config.json` 与 `video_preprocessor_config.json`（视觉输入） |
| draft | `manateelazycat/Qwen3.8-Flash-Next-SGLang-Thor` @ `b8c4002b…`（HF）/ `v0.2.0-candidate1`（MS） | 1.62 GB，16 文件 | DFlash 草稿模型 |
| optimization | 同 SGLang-Thor 仓 | 0.08 GB，2 文件 | Thor 优化配置 |

要点：

- 原版权重来自 **RadixArk 官方仓**（与未审查版 `gorbatjovy/…-plefp8`
  完全不同的工件谱系），专家按每层 4 组分片，另含 PLE 表 FP8 分片与
  视觉输入配置。
- `config.json`（55,703 B）与 `hf_quant_config.json`（51,667 B）不由
  RadixArk 仓提供，而是被 **SGLang-Thor 仓 `target/` 路径下的版本覆盖**，
  即部署使用 Thor 专用配置而非上游默认。
- 运行时为 **SGLang**：归档 `qwen38-sglang-runtime-cebbf332e09f….tar`，
  控制面常量中出现 `MTP + 32768`、`multi-concurrency` 等字样。推理服务
  参数（并发/上下文/KV/启动命令）需实际部署后从容器观测，本文成文时
  未部署。

## 与未审查版的对照

| 项 | 原版 0.2.6/0.2.8 | 未审查版 0.1.48/0.1.51 + 制品 0.1.8 |
| --- | --- | --- |
| 权重仓 | `RadixArk/Qwen3.8-Flash-Next-NVFP4` | `gorbatjovy/…-plefp8`（HF）/ `manateelazycat/…-PLEFP8-20653659`（MS） |
| 分片布局 | 按层 4 组专家分片 + BF16 件 + PLE 10 片 | 9 主体分片 + graft 分片 + 8 PLE 分片 |
| 草稿 | SGLang-Thor 仓独立 draft 角色 | 主体内嫁接 MTP |
| 配置来源 | SGLang-Thor 仓覆盖 | 制品自带（`fix_nvfp4_config.py` 修复） |
| 运行时 | SGLang（`qwen38-sglang-runtime-…tar`） | vLLM（`runtime-124-0.1.8`） |
| 精度修复 | —（原版无需） | GDN 状态 FP32、BF16 lm_head（代价：单流 −35%、并发 −57%） |

## 部署状态

截至记录日未在算力舱部署（微服控制面运行中）。部署后应补充：服务参数、
SGLang 启动配置、单流/并发基准。
