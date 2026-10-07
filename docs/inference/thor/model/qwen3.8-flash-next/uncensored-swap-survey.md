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

## 8. Stage 1 target-only bring-up 结果（`jpezzulli`，2026-10-07）

- 源：`jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4`（126 GiB，206 shards，
  RadixArk 式 192 routed + 14 model）。手动 docker 启动（`run-flash-next-uncensored-stage1.sh`），
  绕过 managed unit——后者与 RadixArk `prepared.json` / `modelopt_mixed` 绑定；无 runtime-patches
  （BF16 lm_head 下 FP8-head/token-map 补丁为 no-op）。
- 加载：`Using ModelOptModelLoader`，`quant=modelopt_fp4, quant_algo=NVFP4`，load 364.8 s，
  GPU `mem usage=83.36 GB / avail=32.34 GB`；PLE `file-backed mmap ... float8_e4m3fn`
  （47.7 GiB sparse，RSS 上限 4 GiB，随加载 trim）。`--mamba-ssm-dtype float32`。
  两档 KV 预算都正常启动：`max_total_num_tokens=8192` 与 `65536`（后者 avail 33.27 GB）。
- 长 prefill（chunk=512，重复固定流）：8K 986 tok/s；32K 1598；48K 1208；65000 1178
  （约 55 s）。最大可接受输入 **65530**（65535/65536 报 `400 exceeds maximum allowed length`）。
- 能力 A/B（同 10 case ×3，profile `M1M`/runtime `run6`）：**30/30 通过**，含
  `exact-short-output`（27B 曾 0/3）。即该 uncensored target 在这组 gate 上无能力回归。
- over-refusal 探针（12 条 benign-but-sensitive：SQL 防御/勒索软件原理/钓鱼构造/锁具/药物过量
  first-aid/化学混用/恐怖受伤/战争小说/反派独白/暗色笑话/成瘾小说）：**0/12 拒绝**（少数被
  500-token 上限截断，非拒绝）。
- decode 吞吐约 12–21 tok/s，显著低于 `M1M` 的 ~57：因 **BF16 dense（无 FP8）+ 无 MTP**，
  按 Stage 1 约定**不作为性能结论**（非 apples-to-apples）。
- 结论：`jpezzulli` target-only 在 Thor 上**可加载、可跑 32K/64K prefill、无 gate 回归、
  reduced-refusal 生效**。下一步：接 stock draft 测 MTP acceptance（注意第 6 节的 draft
  mismatch 风险），再决定是否值得做 Stage 2 的 production-matched FP8 dense/head 重建。
- 证据（私有）：`/var/lib/thor-flash-next/observations/state-drift-20261006/stage1-jpezzulli{,-64k}.log`；
  `mtp-20261005/run7-ab-uncensored/`；`mtp-20261005/overrefusal-uncensored/`。
  下载件：`/var/lib/thor-inference/flash-next/jpezzulli-orcarouter-uncensored-nvfp4`（126 GiB）。

## 9. Stage 1.5：接 stock（对齐血统）MTP draft

2026-10-07。在 Stage 1 的 uncensored target 上挂 production 的 **stock draft**
（`radixark-7b719225-sglang-b8c4002b/draft`，`Qwen4ExpForCausalLMMTP`，`modelopt_mixed`，3.7 GB；
NEXTN steps=3 / topk=1 / draft=4；QSA MTP index sharing 开启），测 spec acceptance 与
draft-mismatch 假设。

- 加载：target 1042 s + draft 5.6 s，avail ≈ 30.5 GB；健康。
- **加速**：decode tok/s 约 **1.5–2.5×**（target-only ~12–21 → MTP ~27–50）；server 端 253 个
  decode batch 的 `accept rate` **均值 0.77、min 0.03、max 0.97**，accept len 高时 ~3.9/4。
- **能力**：同一 harness 两次——`run8` = **23/30**、`run9` = **30/30**。run8 的失败**全部**是
  `finish_reason=length` 的 no-EOS/跑飞（`exact-short-output` 0/3、`thinking-ledger32-low` 1/3、
  `tool-get-weather` 2/3），**不是错答**；随后 `exact-short-output` 直接请求 5/5、harness 单独
  3/3 均通过。→ 属**运行间不稳定/非确定**（与第 4 节 decode 非确定一致），不是 stock draft 的
  确定性回归。
- **draft mismatch**：server accept rate 跨 prompt/批次波动很大（0.03–0.97），说明存在接受率差的
  区域；但 `meta_info` 的 `spec_accept_*` 是每请求的确定计数（无法逐 prompt 归因），本轮**未能
  干净区分 neutral vs boundary**。即“对齐 draft + uncensored target”导致的 acceptance 崩塌
  **未被证实，也未被排除**。
- **结论（按 ChatGPT 复核收敛口径）**：stock draft **能带来明显加速**（~1.5–2.5×、mean accept 0.77
  说明对齐 draft 与 uncensored target **总体并未严重失配**）；一次完整 suite 出现 no-EOS 抖动
  （run8 23/30），但第二次（run9）未复现，isolated 重跑通过。**当前尚不能把 run8 归因于
  MTP/draft mismatch**——target-only decode 本身已知非确定（第 4 节），且失败可能来自
  shared-prefix/cache/request-order 交互。因此：**先不做同血统 draft、也暂不进 Stage 2**，先做
  Stage 1.5b（下节）。

## 10. Stage 1.5b 计划（低成本、先做；由 ChatGPT 复核提出）

两个 confounder 一次解决，直接回答「stock draft 能否直接复用」和「是否需要同血统 draft」：

1. **per-request acceptance 进 harness**：把 pinned SGLang 的
   `spec_accept_rate / spec_accept_length / spec_num_correct_drafts / spec_num_proposed_drafts /
   spec_verify_ct` 接进 A/B 输出（不改 SGLang）；若这些字段在 `/generate` 的 `meta_info` 里实际是
   累计值，则改从服务端 decode-batch 日志按 prefill 边界分段归因。
2. **draft-mismatch differential**：同一组 neutral + refusal-boundary prompts，
   **aligned target + stock draft vs uncensored target + stock draft**，各 3 次；看低接受率是否
   **系统性集中在 refusal-boundary 类**（若是，证明 alignment mismatch；若各类接近、只是偶发低
   batch，则同血统 draft 无必要）。
3. **stability matrix**：`uncensored target-only` vs `uncensored+MTP`，各跑完整 suite 数次，
   分别用 `shared-prefix` 与 `isolated-prefix`（= per-case 隔离/冷启动）；记录 case order、
   finish reason、prefix/cache 命中、per-request acceptance。
   - 若 23/30 只在 `MTP + shared-prefix` 出现 → 查 speculative recurrent/cache；
   - 若 target-only 也偶发 → 已有 decode 非确定；
   - 若 MTP 在 cold/isolated 稳定、只在长生命周期 shared cache 出问题 → 基本锁定 cache/state
     restore 路径。

拿到这两个答案后再决定是否值得做同血统 draft 或 Stage 2 matched quant。

## 11. Stage 1.5b 结果（2026-10-07）

**(a) per-request acceptance 可用。** `qwen3.8` pinned SGLang 的 `/generate` `meta_info`
`spec_accept_rate/spec_accept_length/spec_num_correct_drafts/spec_num_proposed_drafts/spec_verify_ct`
是**逐请求**的（随 `max_new_tokens` 缩放：40/120/400 → prop 63/162/459），可直接用于 differential，
无需改 SGLang。

**(b) stability matrix**（`run-thor-ab.py`，`THOR_CACHE_POLICY` 切 `shared-prefix`/`isolated-prefix`）：

| 配置 | 结果 |
| --- | --- |
| uncensored + MTP | run8 **23/30**（唯一一次）；run9 / run10-sp / run11-sp / run12-iso / run13-iso 均 **30/30** |
| uncensored target-only | run7 / run14-sp / run15-iso 均 **30/30** |

失败全部是 `finish_reason=length` 的 no-EOS。**run8 的 23/30 在随后 5 个完整 suite 中未复现，
且与 `shared-prefix` vs `isolated-prefix`、以及 MTP 与否都无明显关联** → 是**罕见瞬时抖动**
（与第 4 节已知 decode 非确定一致），**不是** MTP/cache/order 的系统性问题，也**不是** stock draft
的确定性回归。§9 里“不是零成本可复用 / run-to-run instability”的措辞据此收敛。

**(c) draft-mismatch differential**（stock draft，逐请求 `spec_accept_rate`，`max_new_tokens=256`，
每类为**单次**在该类 prompt 上的**均值**；`n` 列出）：

| 类别 | n | aligned target `M1M` + stock draft | uncensored target + stock draft |
| --- | ---: | ---: | ---: |
| neutral | 5 | 0.600 | 0.567 |
| code | 4 | 0.721 | 0.782 |
| refusal_boundary | 8 | 0.505 | **0.537** |

（方法学说明：这是各类 prompt 的**单次均值**，不是“各 3 次”的统计；因此不要把 `0.505→0.537`
这 +0.032 当作“uncensored 反而更匹配”的显著差异。**有意义的结论只是“没有数量级下降”**，即未出现
alignment mismatch 导致的 acceptance 崩塌。）

aligned→uncensored 各类差异 **≤0.06**，且 **refusal-boundary 反而略高**（ChatGPT 设想的
`0.78→0.31` 崩塌**未出现**）。**结论：这个 aligned stock draft 与 uncensored target 没有系统性
错配；同血统 draft 很可能没有必要。** stock draft 可继续复用（给速、稳定；仅存在与 draft 无关的
罕见 no-EOS 抖动）。

**Plan 调整**：不插“同血统 draft”，Stage 1.5b 到此；下一步由 Stage 1 的质量/行为结论 + 本节的
draft 结论共同决定是否进 Stage 2（production-matched `modelopt_mixed` 重建）。
证据：`mtp-20261005/run8..run15-*`、`state-drift-20261006/spec-differential.py|spec-scaling.py`。

## 12. Stage 2 路径与当前阻塞（2026-10-07 侦察）

目标 recipe：uncensored source + `routed experts NVFP4 g16` + `dense/attn/shared/head
FP8_PB_WO block128` + `PLE FP8 E4M3` + `state FP32` + **保留现有 stock draft**。

关键事实（读 pinned SGLang `modelopt_quant.py`）：`FP8_PB_WO` 映射到
`Fp8Config(is_checkpoint_fp8_serialized=True, activation_scheme="dynamic",
weight_block_size=[128,128])`。更准确的说法是 **serialized block-FP8 weight**：**checkpoint 侧只存
FP8 weight + block scale、不存 activation scale，因此无需离线 activation calibration**；但**运行时
激活仍会动态 FP8 量化**（不是纯“weight-only”）。

- **路径 A（ChatGPT 建议：从 OrcaRouter BF16 源重建）**：`orcarouter/Qwen3.8-Flash-Next-Uncensored`
  BF16 = **335 GiB**，主机当前仅 **312G** 可用 → **放不下**（需先大幅清盘或外部存储；且仓库
  config/index 返回 401，疑似 gated）。jpezzulli 的 `base_model = OrcaRouter/Qwen3.8-Flash-Next-
  Uncensored`，但 card 未 pin revision。
- **路径 B（从已通过 Stage 1 验证的 jpezzulli 派生；当前推荐）**：保留其 NVFP4 experts、FP8 PLE、
  FP32 state，把它 **BF16 的 dense/attn/shared/head 机械量化**成 FP8_PB_WO block128：每个
  `[N,K]` 权重按 `[128,128]` 块取 amax，写 `weight`(F8_E4M3) + `weight_scale_inv`(F32
  `[ceil(N/128),ceil(K/128)]`, = amax/448)，并把 quant config 改成 `MIXED_PRECISION` 的
  `FP8_PB_WO` 列表（对齐 production 的 301 项）。**同血统、无需校准、唯一新变量是 FP8 dense/head、
  磁盘够**（126 GiB in + ~126 GiB out < 312G）。
- 无论 A/B，都应按 §6/§10 pin：source repo+revision、ModelOpt 0.46.0 + snapshot、NVFP4/FP8
  include-exclude、block 128、PLE conversion、转换脚本 hash、tensor inventory 期望计数，并落一份
  `conversion manifest`。
- Stage 2 后的验证复用现有资产：静态 tensor inventory；10×3 能力（目标 30/30）；12 over-refusal
  （目标 0/12）；target-only vs stock MTP acceptance；decode 回到接近 current `M1M` 区间；32K/64K
  prefill；**关键新 A/B：Stage1 BF16-dense uncensored vs Stage2 mixed uncensored**（FP8 dense/head
  是否损伤已验证行为）。
- **待确认**：走路径 A（需先清盘/外部存储）还是路径 B（推荐）。

## 13. Stage 2 结果（路径 B：从 jpezzulli 派生 production-matched mixed，2026-10-07）

按路径 B 构造：硬链接 jpezzulli 全量，重写含 301 个 production `FP8_PB_WO` 目标的 4 个
`model-bf16-*` shard——把 BF16 权重按 `[128,128]` 块量化为 **F8_E4M3 + `weight_scale_inv`(F32,
= 块 amax/448)**（先验证 production 约定：每块 fp8 amax 恰为 448）；experts(NVFP4)/PLE(FP8)/
其余保持不动；`config.json`/`hf_quant_config.json` 改成 `modelopt_mixed` / `MIXED_PRECISION` +
397 `quantized_layers`（96 NVFP4 g16 + 301 FP8_PB_WO g128）。脚本 `build-stage2.py` 产出
`conversion-manifest.json`。

**静态核验**（**checkpoint format / tensor inventory / quant layout 与 production 对齐**，尚**未**证明
与 production 转换器逐位等价）：`modelopt_mixed/MIXED_PRECISION`；index **296,776** 张量、
**301** 个 `weight_scale_inv`；`linear_attn.out_proj` → F8_E4M3 [2560,6144] + scale [20,48]；
`lm_head` → F8_E4M3 [248320,2560] + scale [1940,20]；experts 仍 `U8`+`weight_scale`；`ple_
embedding_dtype=float8_e4m3fn`。

**GPU 结果**（`modelopt_mixed` + FP8-head loader 补丁 + stock draft；`--mamba-ssm-dtype float32`）：

| 项目 | Stage 1（BF16 dense） | **Stage 2（mixed）** |
| --- | --- | --- |
| 加载 | 83.4 GB | **78.0 GB**（FP8 dense 更省） |
| 能力 A/B（10×3，+MTP） | run9 30/30 | **29/30**（仅 `python-interval-repair-ast` 2/3，`finish=stop` 内容级 gate 抖动，非 no-EOS/错答） |
| over-refusal（12） | 0/12 | **0/12** |
| decode tok/s（thinking） | ~21（target-only）/ ~50（MTP） | **~57–60**（回到 M1M 区间） |
| acceptance neutral/code/refusal | ~0.57/0.78/0.54 | 0.641/0.747/0.527（与 aligned 0.600/0.721/0.505 同量级） |
| prefill 8K/32K/65K tok/s | 986/1598/1178 | **887/1451/2059**（**该 65K 数字受前缀缓存污染，见 §14；不可作 FP8 增益结论**） |

**结论**：把已验证行为的 uncensored target 恢复成 production 的 dense/head/PLE 配方后，
**未观察到对已验证行为的损伤**（over-refusal 0/12 保持；能力唯一一次 29/30 见 §14 复核），且
**decode 回到接近 production（M1M）水平**。Stage 2 artifact 是可行的 production candidate。

**边界/待办**：① 29/30 的 1 次是内容级抖动，需要在 soak（多小时/数百请求，盯 no-EOS 与
gate flake 率）中确认；② provenance 是**从 jpezzulli 派生**（其 `base_model` =
`OrcaRouter/Qwen3.8-Flash-Next-Uncensored`，card 未 pin revision），不是从 OrcaRouter BF16 源
直接重建；若要严格可复现，需补 pin 源 revision 或改走路径 A；③ 目标 artifact 在
`/var/lib/thor-inference/flash-next/jpezzulli-stage2-mixed`（123G，硬链接自 jpezzulli）。
证据：`mtp-20261005/run16-ab-stage2/`、`overrefusal-stage2/`、`state-drift-20261006/stage2-*.log`。

## 14. ChatGPT 复核后的修正与收尾（2026-10-07）

按复核意见修正/补充：

1. **prefill A/B 的 confound 已定位**：两个 run 的 `chunked_prefill_size` **都是 512**（不是 chunk
   混淆）。真正原因是**测量循环里没有在长度之间 flush**——65000 那次复用了前一个 32768 的前缀缓存，
   于是 `prompt_tokens/wall` 被抬高。服务端**每 batch** 输入吞吐：Stage1 ~1054–1087 tok/s、
   Stage2 ~922–987 → **chunk=512 下 FP8 dense 的 prefill 并没有更快（甚至略慢）**。§13 的“1.75×
   long-prefill”结论**撤销**；待做 clean same-chunk、**每次 flush** 的重测（Stage1 BF16 vs
   Stage2 FP8，各 2–3 次）。
2. **reproducibility 落 repo**：新增
   - `utils/build-flash-next-stage2.py`（转换脚本）
   - `utils/verify-flash-next-stage2.py`（静态核验，`--expect-targets 301`）
   pin：
   - 输入 = `jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664`
   - 输入 `model.safetensors.index.json` sha256 `63ff08d02f3c4d262c567ecaa42d01f504a08d048d51614c24ee258426ae9159`；
     `config.json` sha256 `a39bdf4478c9805b3c294a28df6bd7ae43b8a63f81b6a345e6e6c934b097fbaf`
   - 命令：先 `cp -al <jpezzulli> <out>`，再
     `python3 build-flash-next-stage2.py <jpezzulli> <out> <prod/config.json> --no-link`
   - 产物核验：301 targets / index 296776 / 301 `weight_scale_inv` / `ple_embedding_dtype=float8_e4m3fn`
   **lineage 说明**：Stage2 的实际输入是 jpezzulli artifact，不是 OrcaRouter BF16；jpezzulli 的
   base = `OrcaRouter/Qwen3.8-Flash-Next-Uncensored`（card 未 pin source revision）。因此
   **上游 lineage 不完整**，但 `jpezzulli@rev + build-stage2@rev → stage2 artifact` **本身完全可
   复现**——无需下载 335 GiB BF16 源。
3. **转换器逐位验证（已完成，通过）**：下载公开 `RadixArk@7b719225` 的 4 个 `model-bf16-*`
   （15 GB），用 `build-flash-next-stage2.py` 的算法量化 5 个代表 shape，与现有 production 的对应
   FP8 `weight + weight_scale_inv` 做 **byte-level 对比**——**全部逐字节一致、scale max diff = 0**：

   | 张量 | weight byte-identical | scale byte-identical |
   | --- | --- | --- |
   | `linear_attn.out_proj` [2560,6144] | ✅ | ✅ |
   | `shared_expert.down_proj` [2560,640] | ✅ | ✅ |
   | `self_attn.q_proj` [12288,2560] | ✅ | ✅ |
   | `linear_attn.in_proj_qkv` [10240,2560] | ✅ | ✅ |
   | `lm_head` [248320,2560] | ✅ | ✅ |

   → **证明路径 B 的机械转换精确重现了 production 的 FP8_PB_WO converter**（比“amax/448 看起来对”
   强得多）。因此可以把 Stage2 的 dense/head 侧称为 **converter byte-identical to production**（注意
   仅 dense/head 侧；experts 沿用 jpezzulli、PLE 沿用 FP8，这两者本就不是 production 的血统）。
4. **29/30 严格化**：Stage2 这次失败是 `python-interval-repair-ast` 2/3、`finish=stop` 的**内容级**
   gate miss，与之前 `finish=length` 的 no-EOS transient **不是同一失败模式**；且 Stage1 3/3 →
   Stage2 2/3，唯一变量正是 dense/head FP8。**不能直接归为已知 flake**。计划：该 case 做
   **Stage1 vs Stage2 各 10–20 次 targeted A/B**（同 seed/config/cache policy）；并给该 Python
   case 加一个真正**执行**生成代码的 semantic gate（现 gate 只查 AST，20/20 也只证明“像正确程序”）。
5. **措辞**：`FP8_PB_WO` = **serialized block-FP8 weight**（checkpoint 无 activation scale、无需离线
   校准，但运行时激活仍动态 FP8 量化）；“recipe-identical” 降级为 **format/inventory/layout 对齐**
   （pending 第 3 点逐位验证）。

**下一步（这三点过后，不再做研究性实验）**：managed Nix unit → production soak → 晋升。

## 15. 复核后的 clean 重测（2026-10-07）

**Clean prefill**（每次请求前 `flush_cache`，`cached_tokens=0`；两臂均 `chunked-prefill-size=512`
+ stock MTP）：

| 长度 | Stage1（BF16 dense） | Stage2（FP8 dense） |
| ---: | ---: | ---: |
| 8K | 994 tok/s | 963 |
| 32K | 1166 | 1118 |
| 65K | 1117 | 1070 |

→ **chunk=512 下 FP8 dense 的 prefill 没有增益（反而略慢 ~3–4%）**。§13 的“65K 1.75×”确认为**前缀
缓存测量伪影**（65000 复用了前一请求的 32768 前缀），已撤销。这与之前 RadixArk production 的 chunk
sweep 一致：prefill 提速来自 **chunk 512→4096/2048**，而非 dense FP8。

**Targeted python A/B**（`python-interval-repair-ast`，`isolated-prefix`，seed 42，×15）：
**Stage1 15/15、Stage2 15/15** → run16 的 2/3 是噪声，**无 FP8 dense/head 退化证据**。

**遗留**：该 Python gate 仅查 AST；建议后续补一个真正**执行**生成代码的 semantic gate（不影响本轮
结论）。

**结论**：ChatGPT 的两个存疑（prefill confound、python gate flake）均已用 clean 实验解决；
dense/head 侧 **converter byte-identical to production**（§14）；行为侧（capability 30/30 基线、
over-refusal 0/12、python 15/15）无 FP8 退化。Stage 2 具备进入 **managed Nix unit → soak → 晋升**
流程的条件。

## 16. Stage-2 soak（2026-10-07）

配置：Stage 2 `mixed` + stock MTP + FP32 state，`--max-total-tokens 8192`（同 production `M1M`），
`shared-prefix`。

| 项目 | 结果 |
| --- | --- |
| capability 10 case × 10 = 100 请求 | **100/100 通过**；finish = stop×90 + tool_calls×10，**无 `length`/no-EOS** |
| over-refusal 12 × 10 = 120 请求 | **0/120 拒绝** |

合计 **220 请求：0 gate failure、0 no-EOS、0 拒绝**。早前 `run16` 的 2/3 与 `run8` 的 no-EOS 均**未
复现**，支持“罕见一次性”而非系统性问题。证据：`mtp-20261005/soak-ab/`、`soak-overrefusal/`。

**下一步（production 化，需人工拍板）**：
1. managed Nix unit——把 Stage 2 model source + `conversion-manifest.json` 变成声明式选项、加
   prepared/manifest 校验、`nix build`+部署；
2. 更长 soak（多小时/数百请求，盯 no-EOS 与 gate flake 率）；
3. 可选：给 Python gate 加**执行语义**校验（现仅 AST）；
4. 晋升（本仓 `prod` 分支把关）。

Stage 2 candidate：`/var/lib/thor-inference/flash-next/jpezzulli-stage2-mixed`（123 G，硬链接自
jpezzulli）；手动 harness 脚本在私有 obs（`run-stage2.sh`）。
- 证据：`state-drift-20261006/stage1.5-jpezzulli.log`；`mtp-20261005/run8-ab-uncensored-mtp/`、
  `run9-ab-uncensored-mtp/`、`spec-metrics*.py`。
