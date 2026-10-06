# Qwen3.8-Flash-Next 换 model 前的 refusal-removed checkpoint 静态调查

2026-10-07。目的：在把 production target 换成 refusal-removed（uncensored/abliterated）Flash-Next
之前，静态判断哪个 checkpoint 能**最小改动**复用当前 SGLang `modelopt_mixed` + MTP + PLE +
FP32-state 配置。**本页只做 artifact diff（HF 元数据 + 部署 checkpoint 的 safetensors header /
config / index），未上 GPU。**

## 1. production baseline 的实际配方（重要：公开 RadixArk ≠ 部署 artifact）

部署 target：`/var/lib/thor-inference/flash-next/radixark-7b719225-sglang-b8c4002b/target`
（`prepared.json` pin `RadixArk/Qwen3.8-Flash-Next-NVFP4@7b719225` +
`manateelazycat/Qwen3.8-Flash-Next-SGLang-Thor@b8c4002b`）。

直接读部署 safetensors header 与公开 HF repo 的同一张量对比：

| 张量 | 公开 RadixArk@7b719225 | 部署 production |
| --- | --- | --- |
| `model.language_model.layers.0.linear_attn.out_proj.weight` | **BF16** [2560,6144] | **F8_E4M3** + `weight_scale_inv` F32 [20,48] |
| `model.language_model.layers.0.mlp.shared_expert.down_proj.weight` | BF16 [2560,640] | F8_E4M3 + scale [20,5] |
| `lm_head.weight` | BF16 [248320,2560] | F8_E4M3 + scale [1940,20] |
| index 张量数 | 296,475 | 296,776（多 301 个 `weight_scale_inv`） |

即：

- **公开 `RadixArk/Qwen3.8-Flash-Next-NVFP4`**：ModelOpt 0.46.0（snapshot `87c9f8cf`）**只量化
  routed experts**（NVFP4 W4A4, group16）；attn / GDN / shared_expert / lm_head 全 **BF16**；
  PLE 用官方 FP8 表（`text_config.ple_embedding_dtype = float8_e4m3fn`，128 个 F8_E4M3 shard +
  每表 scalar scale）；MTP 与其余保持源精度。
- **部署 production**：= 上述基础上叠加 **FP8_PB_WO(block128)** 的 `self_attn.{q,k,v,o}`、
  `linear_attn.{in_proj_qkv,in_proj_z,out_proj}`、`mlp.shared_expert.{gate,up,down}`、`lm_head`
  （301 个 `weight_scale_inv`），即 `quant_method=modelopt_mixed` / `MIXED_PRECISION`
  （96 项 NVFP4 experts + 301 项 FP8_PB_WO）；MTP 单独 draft（NVFP4 experts）+
  `draft-head-32768-corpus-fp8` token map；recurrent state FP32。

**警告：以后不要把“公开 RadixArk NVFP4”和“部署的 modelopt_mixed artifact”当成同一个东西。**
二者 dense/attn/head 的 dtype 不同（BF16 vs FP8_PB_WO），是两条不同的量化配方。

## 2. 候选矩阵（uncensored/abliterated）

| 仓库 | 血统 | experts | dense/attn/head | PLE | 打包 | 与 production 距离 |
| --- | --- | --- | --- | --- | --- | --- |
| `jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4` | OrcaRouter uncensored | NVFP4 g16 | **BF16** | **FP8 E4M3** | 206 shards 逐专家（RadixArk/SGLang 式） | 同公开 RadixArk 配方；缺 FP8 dense/head |
| `dealignai/Qwen3.8-Flash-Next-ABLITERATED-NVFP4` | Qwen 官方 abliterated | NVFP4 g16 | BF16 | FP8 E4M3 | 206 shards + audit（同式） | 同上；env 与 production 相同 |
| `huginnfork/Qwen3.8-Flash-Next-NVFP4-Abliterated` | `local-inference-lab` QAD NVFP4 | NVFP4 g16 | **MXFP8 block32** | **NVFP4 g16** | 标准 41-shard | 差异最多，排除 |
| `orcarouter/Qwen3.8-Flash-Next-Uncensored` (BF16) | Qwen 官方 abliterated | BF16 | BF16 | BF16 | 标准 | 重建源（非成品） |
| `primitive-ai/...mixed-NVFP4-FP8` | ? | compressed-tensors | — | — | — | 非 SGLang modelopt 路径 |
| `orcarouter/...-NVFP4`、`mazinb/...-NVFP4`、`gitcommit90/...-DenseFP8` | — | gated/不可读 | — | — | — | 无法静态核验 |

## 3. `huginnfork` 逐张量/config diff（优先项）

- **架构完全一致**：48 层 / hidden 2560 / 24 heads / 2 KV / 512 experts（top-10）/ moe 640 /
  shared 640 / vocab 248320 / `layer_types` 相同；`text_config` 55 键逐一相同。
- **base 血统不同**：parent 是 `local-inference-lab/Qwen3.8-Flash-Next-NVFP4`（**QAD 蒸馏**
  step5500 + PLE 1000），不是 RadixArk。
- **量化格式不同**（`export-manifest.json` + `hf_quant_config`）：`modelopt MIXED_PRECISION`，
  routed experts NVFP4 g16；**shared_experts / MTP experts = MXFP8 block32**；attn-out / embed /
  `ple.value_proj` / lm_head = BF16；**PLE = NVFP4 g16**。
- **`text_config.ple_embedding_dtype`：huginn = `nvfp4`，production = `float8_e4m3fn`。**
- **tensor 名集合**：与 production 共同 **296,472**；only-prod 304、only-hug 3,345。
  - only-prod：约 301 个 `weight_scale_inv`（FP8_PB_WO dense/attn/head）、融合 MTP
    `mtp.layers.0.mlp.experts.gate_up_proj/down_proj`、`lm_head.weight_scale_inv`。
  - only-hug：MXFP8 `weight_scale`（shared_expert 等）、**逐专家 MTP experts**
    (`mtp.layers.0.mlp.experts.{0..511}.{gate,up,down}_proj.weight/_scale`，~3,072 个)、
    PLE 逐 shard `weight_scale`。
- **结论：不能最小改动复用。** 需要 SGLang 的 MXFP8 权重加载/反量化（现有 Thor 路径是
  FP8_PB_WO）、MTP 专家布局适配、PLE NVFP4 loader；且 base 是 QAD，另有额外变量。

## 4. 从 `orcarouter` BF16 重建严格 matched NVFP4 的可行性

- 源：`orcarouter/Qwen3.8-Flash-Next-Uncensored`，官方 `Qwen/Qwen3.8-Flash-Next` 的 BF16
  abliterated，保留 vision(333) + MTP(31)，架构与 production 同款；repo 对 config/index 返回
  **401（gated）**，静态只能读 README，无法逐张量核验。
- 要“严格 matched”到 production，需要完整重做：routed experts → NVFP4 g16（ModelOpt 0.46.0 /
  `87c9f8cf`）；`self_attn`/`linear_attn`/`shared_expert`/`lm_head` → FP8_PB_WO block128；
  PLE → `float8_e4m3fn`；recurrent state 保持 FP32；MTP 与所选 uncensored target 同血统。
- RadixArk qualification notes 明确：同一 source 的两次转换因**重复激活捕获**而**不保证
  byte-equal**。所以要真正可复现，必须 pin：校准数据集 + revision/hash + 采样顺序 + seed、
  ModelOpt revision、转换脚本、include/exclude regex。
- **结论：结构上可行，但不是配置切换**，是一次完整量化工程（GPU + 校准），外加 MTP draft 一致性。
- 附：`orcarouter` 已有 gated 的 `Uncensored-FP8` 与 `Uncensored-NVFP4`，可作为“dense FP8 +
  专家 NVFP4 拼装”的候选，但未证实是 modelopt_mixed。

## 5. 最接近可复用的 uncensored 项（静态）

`jpezzulli/...-ModelOpt-NVFP4` 与 `dealignai/...-ABLITERATED-NVFP4`：

- 都是 **experts-only NVFP4 g16 + FP8 E4M3 PLE**（`ple_embedding_dtype=float8_e4m3fn`，
  与 production 相同），ignore 列表同公开 RadixArk（13 项）；206 shards 逐专家布局。
- `dealignai` 的 `conversion_environment.json` = ModelOpt **0.46.0 / `87c9f8cf`**，与
  production 转换环境一致。
- **差别只在 dense/attn/shared/head 回 BF16。** 因此它们复用 SGLang **NVFP4（experts-only）**
  路径即可，但要放弃 FP8 dense/head：`--quantization` 走 `modelopt`/NVFP4；生产里的
  FP8-head loader 补丁（`vocab_parallel_embedding.py.patch`）与 token-map 反量化补丁
  (`eagle_worker_v2.py.patch`) 对 BF16 lm_head 应为 **no-op**（32768 token-map 路线同时失效）。

## 6. 建议执行顺序（两阶段）

1. **Stage 1（target-only，不上 MTP）**：取 `jpezzulli`（首选）或 `dealignai`，固定 FP32
   recurrent state；先验 loader / 内存 / 32K–64K prefill，跑现有能力 A/B + 一套**真实
   over-refusal regression set**（20–30 条源自实际误拒），**不**对 production 做性能同位结论。
2. **draft mismatch 风险**：production MTP draft 来自 aligned 血统；uncensored target + aligned
   draft 仍 target-correct，但在“原版想拒绝、uncensored 想继续”的 token 区 draft 分布偏远 →
   acceptance 掉、加速变小，容易误判成“uncensored 变慢”。故先 target-only，确认值得用后，
   再接 stock draft 看 acceptance，再决定是否做同血统 draft。
3. **Stage 2（仅当 Stage 1 满意）**：以 `orcarouter` BF16 为源做 production-matched
   `modelopt_mixed` 重建，pin 住第 4 节列出的全部校准/工具链参数。

## 7. 证据与限制

- 数据来自 HF resolve/tree（含 LFS header range 读取）与本机部署 checkpoint header；
  原始 fetch 暂存于本机 `/tmp/opencode/hfdiff/`（未入库）。
- 相关 revision：RadixArk `7b719225…`（公开 main 2026-08-26）；huginnfork
  `2d064773…`（2026-09-28）；orcarouter（2026-10-02，gated）；jpezzulli/dealignai main。
- 未上 GPU；gated 仓库（orcarouter/mazinb/gitcommit90）未核验；未做数值/质量验证。
