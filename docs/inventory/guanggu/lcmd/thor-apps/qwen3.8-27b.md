# Qwen3.8-27B：Lazycat 应用部署与基准测试

[Thor 概览](../../../../inference/thor/README.md) ·
[本地 SGLang 部署与调优](../../../../inference/thor/model/qwen3.8-27b/sglang.md) ·
[原版 NVFP4 本地实验](../../../../inference/thor/model/qwen3.8-27b/original.md)

检查与试验日期：2026-09-18。本文记录一台 Thor T5000 上的 Lazycat 官方应用及预构建算力舱运行时；使用 Lazycat 检查点自行组装的 SGLang 部署另见 [sglang.md](../../../../inference/thor/model/qwen3.8-27b/sglang.md)。

测试版本：

- AI Pod：`2.2.4-nightly.20260917081204+43444c8`；
- Lazycat 算力舱固件（`算力舱固件`）：
  `2.2.4-nightly.20260917081206+43444c8`;
- Lazycat Qwen 3.8 27B 应用/LPK：`0.1.58`；
- 内置管理镜像：`0.1.57-amd64-v1`；
- 已部署模型版本：`0.5.1`；
- 算力运行时：`runtime-160-0.2.2-modelopt-nvfp4-draft`。

官方系统上的测试使用算力舱控制面板的性能风扇配置（`风扇-性能模式`）。重启进入 NixOS 后，适配的 Lazycat 温控守护进程以静音配置（`<Max-Q>`）重新生成运行时配置，尽管 AI Pod 后端仍保留 `<Max-P>`。因此，随后的自托管 SGLang 调优及限定时长的稳定性测试使用了静音配置。GPU 时钟维持在 1,385--1,386 MHz，未观察到因温度导致的性能下降，因此归因分析和内核相对性能比较仍然有效。后续另用机群自有的性能曲线复测，并在下文单独标明。参见[温控检查](../thor/lzc-thermal.md)。私人地址、主机名、凭据以及用户和设备标识符均已省略。

## Lazycat 管理应用

已安装的软件包为 `cloud.lazycat.aipod.qwen38-27b`，显示名称为“Qwen 3.8 27B 未审查版”。其清单使用管理镜像 `registry.lazycat.cloud/catdogai/qwen38-27b-lpk:0.1.57-amd64-v1`；软件包元数据本身为更新一个修订版的 0.1.58。

持久化的部署记录显示：

- 模型 ID 为 `qwen-3.8-27b-uncensored`，模型版本为 `0.5.1`；
- 模式为 `custom`，请求并发数为 8，`maxNumSeqs` 为 8；
- 上下文长度为 512,000；
- 预计设备内存占用 76.5 GiB，预计剩余 43.4 GiB；
- 运行时镜像为
  `registry.lazycat.cloud/catdogai/qwen38-27b:runtime-160-0.2.2-modelopt-nvfp4-draft`.

观察到的重启耗时 120.43 秒。更早的首次部署日志持续约 23 分 34 秒，其中包括运行时镜像的传输与导入。后续重启复用了本地镜像和 43.1 MiB 的热缓存归档，因此两次耗时不可直接比较。

## 算力运行时

ARM64 运行时镜像的摘要为
`sha256:5641d0ab6b2085572cae5080d80b6b624fc346af0228a2840bf785fbbfc75062`,
创建日期为 2026-09-15，本地镜像大小为 57.33 GiB。部署记录中的磁盘空间估算为 61.56 GB。

镜像标签标明 vLLM 修订版本为
`18f658bb3185779ee58999a328246d09886d568b`，DFlash2 修订版本为
`3406ec1dae9916f920b90f0dbf90dcf54923d042`。目标模型为
`joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt`，修订版本为
`e5ff4986938dcd0dd05ab4cce89da1b052be6ce3`；校准后的 NVFP4 草稿模型为
`maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal`，修订版本为
`bd7a934213c47a9e7ef69eef36bb3325f47fd1f1`.

观察到的软件版本：

| 组件 | 版本 |
| --- | --- |
| Python | 3.12 |
| Torch | 2.11.0 |
| vLLM | `0.0.0+18f658bb3185` |
| FlashInfer | 0.6.17 |
| Triton | 3.6.0 |
| Transformers | 5.12.1 |

目标模型权重文件为 18.39 GiB，嫁接的 MTP 文件为 0.79 GiB，DFlash2 草稿模型为 1.44 GiB。目标模型和草稿模型均使用 ModelOpt NVFP4，目标模型的线性层后端选用 CUTLASS。

### 检查点来源与布局

镜像中的两个检查点均为公开、无需申请访问权限的 Apache-2.0 Hugging Face 工件。镜像固定了确切的修订版本，而非可变的分支名称：

- [joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt](https://huggingface.co/joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt/tree/e5ff4986938dcd0dd05ab4cce89da1b052be6ce3),
  修订版本 `e5ff4986938dcd0dd05ab4cce89da1b052be6ce3`；
- [maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal](https://huggingface.co/maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal/tree/bd7a934213c47a9e7ef69eef36bb3325f47fd1f1),
  修订版本 `bd7a934213c47a9e7ef69eef36bb3325f47fd1f1`。

目标模型的 19,743,750,248 字节主权重的 Hugging Face LFS SHA-256 为
`5db0ff93ebdf68034770a6acec123971e618928684bd2d5f3f51346990254911`.
849,400,424 字节的嫁接 MTP 权重的 SHA-256 为
`90fa0e3eed5a647c035c6df9ecabc416c0f8d573ff84ac12485b085f00a7cdf2`.
1,550,153,248 字节草稿模型的 SHA-256 为
`2228b9b22e93a88d84556419c879448ab6c490ae65c4c0b166f4962190ddbf26`.
主目标模型和草稿模型的哈希值均与运行时镜像标签及从镜像提取的文件一致。因此，官方部署逐字节使用了已发布工件；未发现 Lazycat 专属的权重差异。

此目标模型并非当前生产检查点的另一种打包形式。其来源是
[JonathanColetti/Qwen3.8-27B-Uncensored](https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored),
即 Qwen3.8-27B 的消融拒答变体。该仓库将主语言模型的 400 个线性层量化为采用 K16 分块和 FP8 缩放的校准 NVFP4 W4A4。DeltaNet 的 `in_proj_a`、`in_proj_b` 和 `conv1d`，以及输出头、视觉塔和 MTP 头，仍使用 BF16。校准使用了 256 个最长 1,024 token 的 Open-Platypus 样本，之后未再微调。由于检查点每字节打包存储两个 4-bit 值，普通的 Transformers 加载方式无效；运行时必须理解 ModelOpt FP4 布局。

五层 DFlash2 草稿模型将其 35 个线性投影量化为校准后的 NVFP4 W4A4 K16。其目标特征 `fc` 和动态卷积投影仍为 BF16。模型卡报告称，使用 460 段对话进行了 on-policy 校准，接受长度为 3.60/8；未经校准的就近舍入 NVFP4 为 3.26/8，原始 BF16 草稿模型为 3.71/8。最终输出哪些 token 仍由目标模型验证决定；草稿模型量化主要改变草稿计算成本、内存占用和接受情况。

当前生产环境中的模型组合具有不同的来源和精度分配：

| 检查点组合 | 目标模型布局 | 草稿模型布局 | 权重字节数 |
| --- | --- | --- | ---: |
| 当前生产配置 | 原版 Qwen 目标模型；208 个 attention/DeltaNet 投影使用 FP8，192 个 MLP 投影使用 NVFP4，输出头使用 BF16 | BF16 z-lab DFlash2；运行时应用本地 INT8 输出头优化 | 27,598,150,584 |
| Lazycat | uncensored 目标模型；400 个主要投影使用 NVFP4，精度敏感部分除外 | 校准后的 NVFP4 DFlash2 | 22,143,303,920 |

Lazycat 模型组合小约 5.08 GiB，因此为 KV 缓存留出更多统一内存；但这也意味着吞吐量和生成 token 的差异不能只归因于推理服务引擎。目标模型的语义权重、目标模型量化及草稿模型量化均发生了变化。

两个目标模型目录具有相同的聊天模板、词表、新增 token 和语义 BPE 合并表。但其 tokenizer 序列化并不完全相同：填充 token、组合附加符号的预分词表达式及 ByteLevel 标志存在差异。常见基准文本预计会得到相近的分词结果，但边界 Unicode 情况和批量填充仍是额外变量。

无需使用 Lazycat 镜像，也可通过以下命令下载这一确切的模型组合：

```console
hf download joshebbs/qwen3.8-27b-uncensored-nvfp4-modelopt \
  --revision e5ff4986938dcd0dd05ab4cce89da1b052be6ce3 \
  --local-dir ./qwen38-lazycat-target
hf download maurienne-ai/Qwen3.8-27B-DFlash2-NVFP4-RTNcal \
  --revision bd7a934213c47a9e7ef69eef36bb3325f47fd1f1 \
  --local-dir ./qwen38-lazycat-draft
```

主要推理服务配置：

| 设置 | 观察值 |
| --- | --- |
| 调度器 | 8 个序列，4,096 个批处理 token，禁用异步调度 |
| 上下文 | 512,000-token YaRN 视图，由原生 262,144 扩展，系数 1.953125 |
| KV 缓存 | 44.5 GiB，容量 539,789 token，块大小 864 |
| 前缀缓存 | 已启用，使用 SHA-256 哈希 |
| 推测解码 | 量化 DFlash2 草稿模型，K16 |
| 编译 | Eager 执行；禁用 Torch compile 和 CUDA Graph |
| 量化 | 目标和草稿模型使用 ModelOpt NVFP4；目标模型线性层后端为 CUTLASS |
| Mamba 状态 | 缓存 dtype 为 `auto`；指标报告 FP32 SSM 状态 |
| 网络 / IPC | 主机网络模式 / 主机 IPC |
| 容器权限 | NVIDIA 运行时、`IPC_LOCK`、非特权 root |

vLLM 警告称，在 16-token 推测窗口下，4,096 个调度 token 的上限可能并非最优。封装程序还将 4 GiB GPU 内存限制转换为 `gpu_memory_utilization=0.032557`，而部署配置另行指定了 44.5 GiB 的 KV 分配。指标同时反映了两个值；实际缓存分配应由明确的 KV 容量描述，不能仅看百分比。

报告的 KV 容量仅相当于同时处理 1.054 个完整的 512,000-token 请求。因此，8 是短请求的调度器上限，而非同时处理 8 个最大上下文请求的容量。

镜像元数据宣称支持 900,000-token 配置，但此部署明确提供 512,000-token 服务。不能将镜像能力与已部署 API 的限制混为一谈。

## API 与能力观察

服务暴露 vLLM 的 OpenAI 兼容聊天、补全、responses、Anthropic messages、分词和指标路由。启动时未传入 API key 参数：不带认证、使用错误 bearer token 及使用已配置 token 的模型列表请求均返回 HTTP 200。模型进程也未启用 TLS。因此必须在外部提供网络访问控制。

目标模型配置包含视觉编码器，管理客户端宣称支持文本和图像输入。运行时启用了 Qwen3 推理解析器、Qwen3 XML 工具解析器和自动工具选择。DFlash2 启动日志指出，外部多模态 embedding 不会传入草稿模型；多模态请求对草稿模型使用纯文本输入。

限定范围的冒烟检查全部通过：

- 合成的 32 x 32 纯红色 PNG 在 0.357 秒内返回 `red`；
- 严格 JSON schema 请求准确返回 `{"answer":42,"label":"thor"}`；
- 自动工具选择请求生成了城市为 `Beijing` 的 `get_weather` 调用；
- 正常停止的 Python 请求生成了可解析代码，包含要求的五条断言。

这些检查确认了推理服务路径可用，但不能证明广泛的视觉、工具使用或代码质量。

## 单流测量

三个提示词及输出上限与[此前的本地实验](../../../../inference/thor/model/qwen3.8-27b/original.md#方法与结果)一致。每种负载先进行一次 32-token 预热，然后执行三次测量请求。温度设为零，禁用思考，并提供固定种子。服务没有重置前缀缓存的路由，因此每次请求使用独立的 `cache_salt`，在保持提示词完全相同的同时避免缓存复用。解码速率按 `(completion tokens - 1) / (stream end - first content)` 计算。

| 负载 | 输出上限 | 解码速率 | 中位数 | 首个内容延迟中位数 | DFlash 接受 / 提议 token |
| --- | ---: | --- | ---: | ---: | ---: |
| 中文 | 256 | 17.37, 17.40, 17.37 | 17.37 tokens/s | 0.152 s | 369 / 6,384 (5.8%) |
| 短代码 | 256 | 62.37, 62.38, 62.34 | 62.37 tokens/s | 0.148 s | 660 / 1,776 (37.2%) |
| 长代码 | 1,024 | 79.48, 79.49, 79.59 | 79.49 tokens/s | 0.153 s | 2,727 / 5,568 (49.0%) |

所有测量响应均达到长度上限，因此代码吞吐量并不代表完整代码的正确性结果。每种负载的三次响应具有相同哈希值，与同一测试期间观察到的非确定性 Flash Next 部署不同。

厂商产品页面公布的单流速率范围为 49–135 tokens/s。两种代码负载均处于该范围内；中文负载低于此范围，因为 DFlash 接受率仅为 5.8%。提示词和生成文本的可预测性会显著影响推测解码吞吐量。

## 八请求并发

先进行一批预热，再测量三批请求。每批同时提交八份短代码负载，输出上限为 128 token。独立的缓存盐防止请求间复用前缀。聚合解码统计从首个内容事件到最后一个流完成期间交付的所有 token。

| 批次 | 聚合解码速率 | 批次实际耗时 | 单请求解码速率中位数 | 单请求 TTFC 中位数 |
| --- | ---: | ---: | ---: | ---: |
| 1 | 179.51 tokens/s | 5.828 s | 23.37 tokens/s | 0.387 s |
| 2 | 179.50 tokens/s | 5.823 s | 23.38 tokens/s | 0.385 s |
| 3 | 179.46 tokens/s | 5.823 s | 23.37 tokens/s | 0.384 s |

聚合速率中位数为 179.50 tokens/s，DFlash 在 8,880 个提议 token 中接受了 2,517 个（28.3%）。该速率比厂商展示的 182–423 tokens/s 范围下限低 1.4%；差距很小，因此确切提示词、输出长度和计时边界都会影响比较。

## 预填充与上下文容量

一次预热和三次测量请求均使用恰好 5,001-token 的聊天提示词及 32 个输出 token。独立的缓存盐强制重新计算全部提示词 token。首个内容延迟分别为 2.612、2.616 和 2.607 秒，中位数为 2.612 秒。vLLM 将其中 2.572–2.576 秒归于预填充，计算速率中位数约 1,941 tokens/s；排队时间仅为 8–12 微秒。

产品页面报告 5K 输入的 TTFT 为 2.49 秒，预填充速率为 2,133 tokens/s。观察到的 TTFT 中位数慢 4.9%，内部预填充速率低 9.0%。由于确切文本和计时定义可能不同，这只是观察性比较，不能视为受控的性能回归。

包含 500,001 个重复普通 token 和一个输出 token 的预分词请求成功完成。整个 HTTP 请求耗时 1,490.30 秒；vLLM 将其中 1,490.00 秒归于预填充，即 335.57 个计算 token/s，排队时间约 30 微秒，未发生抢占。活动 KV 使用率达到约 92.48%，请求完成后回落至零。

长上下文遥测覆盖了该请求的前 879 秒。报告的 GPU 功率平均为 69.05 W，峰值为 74.48 W；GPU 峰值温度为 69.9 C，系统 RAM 使用峰值为 78.15 GB。这些是传感器读数，并非整板输入功率。重复 token 提示词验证的是容量和运行时稳定性，不能验证长上下文检索或回答质量。

构造的 512,001 个输入 token 加一个输出 token 的请求在推理前于 0.077 秒内被 HTTP 400 拒绝。错误消息明确指出总上下文上限为 512,000 token。因此，此部署无法使用镜像的 900K 配置。

## 推理运行期间的进程快照

在八个并发请求均运行期间，采集了一份 root 级进程快照。vLLM 报告等待请求数和抢占次数均为零。Qwen 容器中有四个进程：

| 角色 | 进程 | 线程数 |
| --- | --- | ---: |
| 容器初始化及运行时入口 | `docker-init` | 1 |
| vLLM OpenAI API 前端 | `vllm.real serve` | 62 |
| Python 多进程资源跟踪器 | `multiprocessing.resource_tracker` | 1 |
| 模型执行进程 | `VLLM::EngineCore` | 110 |

完整的主机快照包含 485 个进程和 1,212 个线程。私有工件保留了 root 可见的完整命令行、可执行文件映射、进程树、Docker 进程列表、cgroup、命名空间、套接字及同期 GPU 状态；由于整机列表包含无关的环境特定信息，这些工件未放入公开仓库。

## 运行观察

此部署之后，算力舱根文件系统报告仅剩约 3 GiB 可用空间，使用率四舍五入后为 100%。测试没有额外消耗大量磁盘空间，但未来镜像更新、缓存写入和日志增长的余量很小。将此部署用作长期服务前应解决该问题。

空闲时，整机 125.8 GB RAM 中约有 77.9 GB 被占用，Qwen 容器报告普通 cgroup 内存占用约 7.0 GiB。500K 请求期间，系统 RAM 用量保持在约 78.1 GB，因为较大的 KV 空间已在启动时预留；活动 KV 块增加并未导致主机新增数十 GiB 内存分配。

## 测量现状与后续工作

本文已足以作为官方应用、单流及八请求解码、5K 预填充、API 能力、接近上限的容量和运行中进程布局的初步版本固定记录。后续值得进行的工作包括：

1. 在多个深度测试长上下文检索；重复 token 的容量请求无法衡量 YaRN 质量。
2. 在受控 A/B 测试中比较 eager 执行与经过验证的 CUDA Graph 配置，并提高 4,096 个调度 token 的上限。
3. 在将产品页面上的小幅差异视为性能回归前，获取厂商使用的确切提示词和计时定义。
4. 先确定安全的内存和磁盘预算，再复现镜像的 900K 配置；不要从成功的 500K 请求推断其可用性。

原始请求、计数器、遥测数据及进程清单均保留在公开仓库之外。

## 参考资料

- [本地 SGLang 部署与调优（Lazycat 检查点）](../../../../inference/thor/model/qwen3.8-27b/sglang.md)
- [此前的本地原版 NVFP4 实验](../../../../inference/thor/model/qwen3.8-27b/original.md)
- [厂商公布的性能快照](../../../../inference/thor/README.md#厂商公布的性能快照)
