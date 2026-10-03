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

### 基准复测（2026-10-03）

负载提示词、输出上限（中文 128/代码 256 固定长度、JSON 自然停止）、温度
为零、禁思考、预热后测三次、解码速率口径与未审查版各次测量一致；种子
42。前缀缓存以 SGLang `/flush_cache` 在每次请求前清空（首次 260K 测量
因构造探测的缓存命中得出 5.3 s 的无效值，已重测）。SGLang 无
`cache_salt` 依赖。

#### 单流

| 负载 | 输出 token 数 | 解码速率 | 中位数 | 首个内容延迟中位数 |
| --- | ---: | --- | ---: | ---: |
| 中文 | 128 | 25.20, 28.29, 29.96 | 28.29 tokens/s | 0.320 s |
| 代码 | 256 | 53.74, 64.48, 65.38 | 64.48 tokens/s | 0.306 s |
| JSON | 20 | 56.28, 63.25, 69.64 | 63.25 tokens/s | 0.310 s |

#### 八请求并发

| 批次 | 汇总解码速率 | 批次总耗时 | 单请求速率中位数 | 单请求 TTFC 中位数 |
| --- | ---: | ---: | ---: | ---: |
| 1 | 350.61 tokens/s | 3.39 s | 43.97 tokens/s | 0.493 s |
| 2 | 351.37 tokens/s | 3.44 s | 44.12 tokens/s | 0.559 s |
| 3 | 352.61 tokens/s | 3.39 s | 44.21 tokens/s | 0.518 s |

#### 预填充与上下文容量

5,001-token 提示 + 32 输出：TTFC 0.381、0.484、0.416 秒，中位数 0.416 秒
（约 12,000 tokens/s）。260,001 输入 + 1 输出成功，整请求 14.21 秒（约
18,300 tokens/s）；265,007-token 请求被 400 拒绝，上限 262,000。260K 有效
测量的逐秒遥测未单独截取。

#### 对照与观察

| 项目 | 未审查 0.1.6 基线 | 未审查 0.1.8（修复版） | 原版 0.2.8（SGLang） |
| --- | ---: | ---: | ---: |
| 中文 128 tok | 18.71 | 12.17 | **28.29** |
| 代码 256 tok | 58.66 | 36.20 | **64.48** |
| 8 并发聚合 | 135.84 | 58.38 | **351.37** |
| 5K 预填充 TTFC | 2.945 s | 3.027 s | **0.416 s** |
| 260K 预填充 | 1,486 tok/s | 1,451 tok/s | **≈18,300 tok/s** |

- 原版相对修复版未审查：单流 +78–132%，八并发 +502%，5K 预填充 −86%，
  260K 预填充 12.6 倍。相对基线未审查也全面占优。
- SGLang 指标显示 `spec_accept_length 1.0`、`spec_accept_rate 0.0`（NEXTN
  3 步 × 4 草稿在配置中但观测不到任何接受）——上述速度是在推测解码
  未生效的情况下取得的，属纯步进性能；草稿路径是否真正参与需要另行
  核实（可能为指标口径或草稿词表映射问题）。
- 未审查版的两处精度修复（FP32 GDN 状态、BF16 lm_head）在原版上不适用，
  这解释了修复版与原版之间的解码差距；预填充 12.6 倍的差距主要来自
  运行时（SGLang fa4/fp8 KV vs vLLM）与权重布局差异，而非消融本身。

### 部署落点与工件键

- 算力舱权重缓存键为 **`radixark-sglang-262144-v1`**（区别于未审查版的
  检查点修订哈希键），路径
  `/var/lib/lzc-ai-agent/data/qwen38-flash-next-origin/models/radixark-sglang-262144-v1/`
  下 `target`、`draft`、`optimization` 三个子目录，分别挂载为容器内
  `/model`、`/mtp-nvfp4`、`/vocab-maps`；PLE 卸载目录与编译缓存挂载自
  `cache/qwen38-flash-next-origin/sglang-v1/{ple,cache,model-integrity}`。
- 本次实际下载源为 ModelScope：target 用 `RadixArk/…` @ `a6cc3dfc…`，
  draft/optimization 用 `SGLang-Thor` @ `v0.2.0-candidate1`；逐文件
  `.aipod-verified.json` 校验后入缓存。
- 运行时归档 `qwen38-sglang-runtime-0.2.4.tar` 由 SGLang-Thor 仓提供
  （0.2.8 修复后的原版专属固定归档），导入后即
  `qwen38-flash-next-origin:runtime-sglang-0.2.4`。
