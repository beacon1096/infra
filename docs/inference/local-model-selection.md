# 本地模型能力选型（Embedding / ASR / TTS）

状态：2026-09-30 已在 Mac mini M4 落机并逐项验证 Embedding / ASR / TTS；Kokoro 因 oMLX DMG 的 espeak-ng 打包缺陷暂缓。

结论与部署边界见 [AI 算力设备盘点](ai-compute-inventory.md)，oMLX 应用与模型管理见 [oMLX 容量记录](omlx-model-capacity.md)。

## 结论

Embedding、ASR、TTS 三类轻量能力首轮统一由 Mac mini M4 上的 **oMLX** 单进程提供，通过其 OpenAI 兼容接口接入 Memoh 等调用方。相比为每类能力各起一个框架，oMLX 已经同时注册 `/v1/embeddings`、`/v1/audio/transcriptions`、`/v1/audio/speech`，并原生打包 MLX/MLX-Audio/MLX-Embeddings 运行时，nix-darwin 侧只需维护进程、模型清单与固定 revision。

首轮候选：

| 能力 | 首选 | 对照 | 暂缓 |
| --- | --- | --- | --- |
| Embedding | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | `mlx-community/bge-m3-mlx-8bit` | Qwen3-Embedding 4B/8B |
| ASR | `mlx-community/Qwen3-ASR-0.6B-8bit` | `mlx-community/whisper-large-v3-turbo-asr-fp16` | Qwen3-ASR 1.7B |
| TTS | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` | —（Kokoro 暂不可用） | Qwen3-TTS 1.7B、音色克隆 |
| Rerank | 暂不部署 | — | 等真实检索数据 |

M4 是三类能力的首选验证平台。P4 在推理负载与 PD 供电稳定性验证前不进入首轮；A2000 已验证不能承担关键负载，只用于可中断的兼容性实验。Thor 保持主力 LLM/VLM 角色。

## Embedding

`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` 的 `config.json` 是标准 `Qwen3ForCausalLM`，与聊天模型同架构但不带 `lm_head`。oMLX 只在**目录名或 HF repo 名包含 `embed`/`embedding`** 时才把这种权重判定为 embedding，因此 `services.omlx.models` 的模型键名必须保留该关键字，否则会被当作 LLM 加载。

`mlx-community/bge-m3-mlx-8bit` 作为对照：`XLMRobertaModel` 架构，oMLX 直接识别，不依赖命名启发式，且不依赖 query-only instruction。原 `BAAI/bge-m3` 只有 PyTorch 权重，这里用 MLX 转换版。两个候选都输出 1024 维，便于保持相同的 Memoh 模型配置。

升级到 Qwen3-Embedding 4B/8B 仅在真实检索集显示 0.6B 召回不足时进行，不以 MTEB 分差为依据。

## ASR

`mlx-community/Qwen3-ASR-0.6B-8bit` 架构为 `Qwen3ASRForConditionalGeneration`，oMLX 直接识别。0.6B 适合常驻低延迟，1.7B 只在 0.6B 技术实体准确率明显不足时再评估。

`mlx-community/whisper-large-v3-turbo-asr-fp16` 作为成熟生态对照。注意普通的 `mlx-community/whisper-large-v3-turbo` 只有 `config.json` 和 `weights.safetensors`，缺少 oMLX 加载 Whisper 所需的 `preprocessor_config.json` 与 tokenizer 文件，必须用带 `-asr-fp16` 这类完整导出的仓库。

oMLX v0.7.0rc1 的 ASR 模型集合为 Whisper、Qwen3-ASR、Parakeet、Qwen2Audio；SenseVoiceSmall 不在其中，若确需它面向中文短指令的能力，需要单独运行时。若后续 oMLX 的音频路由出现回归，可退回独立 whisper.cpp 服务，无需改动调用方接口。

## TTS

`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` 架构为 `Qwen3TTSForConditionalGeneration`，带预设音色并支持流式输出，作为交互主力。

`mlx-community/Kokoro-82M-bf16` 原计划作为低延迟对照，但 oMLX 0.7.0rc1 的 DMG 内置的 `libespeak-ng` 使用构建路径 `/Users/runner/work/.../espeak-ng-data`，运行时找不到 `phontab`，合成请求会让整个 oMLX 进程退出。该路径与 `ESPEAK_DATA_PATH` 都修不好，只能等上游修复打包。因此首轮不部署 Kokoro，TTS 仅用 Qwen3-TTS；需要音色克隆时再评估上游修复后的版本。

音色克隆（`Base` 版本、`ref_audio`/`ref_text`）首轮不启用。

## oMLX 服务层（v0.7.0rc1 核对）

仓库的 oMLX 包已从 `0.6.4` 升到 `0.7.0rc1`。核对确认音频与向量路由、模型识别集合、请求字段在升级前后一致：

- `/v1/embeddings`、`/v1/rerank`、`/v1/audio/transcriptions`、`/v1/audio/speech`、`/v1/audio/process` 均在。
- Embedding 识别覆盖 `Qwen3ForTextEmbedding`、`Qwen3ForCausalLM`（目录名启发式）、BERT/XLM-RoBERTa/ModernBERT/SigLIP。
- ASR 识别覆盖 Whisper、Qwen3-ASR、Parakeet、Qwen2Audio。
- TTS 识别覆盖 Kokoro、Qwen3-TTS、Chatterbox、VibeVoice 等。
- 音频请求接收 `prompt`（转写）与 `instructions`（语音合成），并映射到后端。

0.7.0rc1 的发布说明以 LLM 预填充/解码性能为主，未改变上述模型集合与音频 API 契约。

## M4 落机结果（2026-09-30）

公开的 M4 基线已重新启用 `services.omlx`，服务监听 `0.0.0.0:8000`，模型目录 `~/.omlx/models`。实际落地并逐项验证的模型：

- `Qwen3-Embedding-0.6B-4bit-DWQ`：`/v1/embeddings` 返回 1024 维。
- `bge-m3-mlx-8bit`：返回 1024 维。
- `Qwen3-ASR-0.6B-8bit`：Qwen3-TTS 生成的中文音频可正确转写。
- `whisper-large-v3-turbo-asr-fp16`：英文 round-trip 转写正确。
- `Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`：中英文合成都返回 wav。

Kokoro 未部署并从模型清单移除，原因见 TTS 一节。

两个运行时注意点：

- 0.7.0rc1 在绑定非回环地址时禁止 `skip_api_key_verification=true`。已把 `~/.omlx/settings.json` 的该开关改为 `false`，Memoh 必须带 API key。该文件不归 Nix 管理，重建不会重置。
- oMLX 的 `process_memory_enforcer` 启动时会把 `iogpu.wired_limit_mb` 提到 28GB，无需再单独声明 `iogpuWiredLimit`。

## Memoh v0.20.0 集成约束

Memoh 的 OpenAI 兼容 provider 允许覆盖 `base_url`，可指向 oMLX；音频 provider 同样支持自定义端点。落地前需接受以下版本限制：

1. **Embedding 无 query instruction。** 索引写入与查询共用同一 `client.Embed(text)` 调用，无法只给 query 加 Qwen3-Embedding 的 instruction。因此必须用真实 memory 语料实测无 instruction 时的召回，而不是套用模型卡的最佳配置。
2. **Embedding 维度必须匹配。** Memoh 模型配置的 `dimensions` 会校验返回向量长度；Qwen3-Embedding-0.6B 与 BGE-M3 都是 1024。
3. **TTS 不转发 `instructions`。** Memoh 的 OpenAI speech provider 仅在模型 id 包含 `gpt-4o-mini-tts` 时才发送 `instructions`，因此 Qwen3-TTS 的语气/风格控制不会透传，只有固定音色的基础合成可用。若确需风格控制，需要改 Memoh 或加一层薄代理。
4. **ASR `prompt` 可用。** Memoh 发送 `prompt`，oMLX 转写接口接收并映射到 Qwen3-ASR 的 biasing 上下文或 Whisper 的 `initial_prompt`。
5. **模型列表。** Memoh provider 通过 `GET /v1/models` 拉取候选；oMLX 已提供该端点。

## 验收与后续

落机已完成，下一步是用真实数据做质量与延迟验收（指标沿用算力盘点的顺序）。本次 M4 变更在公开仓的 M4 基线里，私有仓仍按 [oMLX 容量记录](omlx-model-capacity.md) 固定完整 revision；要让 comin/发布流水线固化，需要推送公开变更并更新私有仓的 `infra` input。Memoh 侧再新增 openai 类型 provider 指向 oMLX，并分别为 embedding、speech、transcription 建立模型条目。

验收指标：

- Embedding：以 graph-only 为基线，用 100–300 条真实查询做 Recall@5/10/20、MRR、nDCG@10 与 p50/p95 延迟。
- ASR：中文 CER、英文 WER、技术实体准确率与延迟；合成音频只用于回归。
- TTS：首帧延迟、实时率、自然度；确认基础播报是否已满足需求。
