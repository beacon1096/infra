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

## 部署记录（2026-10-03，LPK 0.2.8）

首次实际部署。时间线：下载约 129 GiB（ModelScope，aria2，多次因
TLS/连接问题中断，靠应用 UI 的 Retry 续传，全程约 6 小时）→ 网盘到算力舱
传输约 2.5 小时 → 校验与导入 → 服务启动加载约 40 分钟。部署前清理了
算力舱上未使用的 335 GB 旧运行时镜像 `runtime-134-0.1.6` 以腾出磁盘。
部署会停止同宿主的冲突模型服务：本次后未审查版 Flash Next 服务被停止，
8005 端口由原版接管。

### 服务参数（SGLang，从容器进程实测）

运行时镜像 `registry.lazycat.cloud/catdogai/qwen38-flash-next-origin:runtime-sglang-0.2.4`
（基于 `lmsysorg/sglang:v0.5.20`，构建 `94602c9c…`）。启动命令：

```text
python3 -m sglang.launch_server
  --model-path /sgl-checkpoint --served-model-name qwen-3.8-flash-next
  --port 8005 --api-key ollama --tp 1
  --quantization modelopt_mixed
  --context-length 262000 --max-total-tokens 522176
  --max-running-requests 8 --mem-fraction-static 0.92
  --kv-cache-dtype fp8_e4m3 --mamba-ssm-dtype bfloat16
  --max-mamba-cache-size 40
  --moe-runner-backend flashinfer_cutlass --fp4-gemm-backend flashinfer_cutlass
  --fp8-gemm-backend triton --attention-backend fa4
  --page-size 64 --chunked-prefill-size 4096 --max-prefill-tokens 8192
  --reasoning-parser qwen3 --tool-call-parser qwen3_coder
  --ple-offload-embedding --ple-offload-backend file --ple-offload-dir /ple
  --speculative-algorithm NEXTN --speculative-num-steps 3
  --speculative-eagle-topk 1 --speculative-num-draft-tokens 4
  --speculative-draft-model-path /mtp-nvfp4
  --speculative-draft-model-quantization modelopt_mixed
  --speculative-token-map /vocab-maps/vocab-32768-corpus.pt
  --enable-metrics
```

要点（与未审查版 vLLM 部署对照）：

- 上下文 **262,000 = 原生长度，无 YaRN 扩展**（未审查版为 320K 视图、
  265K 硬上限）；`max-total-tokens 522,176` 配合 **fp8_e4m3 KV**，池容量
  约为上下文的 2 倍。
- MTP 推测解码为 **NEXTN、3 步、topk 1、每步 4 草稿 token**（未审查版
  vLLM 用 K16/MTP），草稿模型为独立 `/mtp-nvfp4`（modelopt_mmixed 量化）
  外加 `vocab-32768` 词表映射。
- `mamba-ssm-dtype bfloat16` 且未做精度修复——原版 lm_head 本身 BF16，
  长上下文漂移问题不存在。
- PLE 表通过 `--ple-offload-embedding` 卸载到文件（`/ple`）。
- 注意力后端 fa4，MoE 与 FP4 GEMM 走 flashinfer_cutlass，FP8 GEMM 走
  triton。
- API 强制 `Authorization: Bearer ollama`（未审查版无鉴权）。

冒烟：`/v1/chat/completions` 以 `qwen-3.8-flash-next` 正常返回。
