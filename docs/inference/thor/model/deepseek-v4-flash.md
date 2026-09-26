# DeepSeek V4 Flash：单台 Thor 可行性

[Thor 概览](../../README.md)

状态（2026-09-26）：本机单台 Jetson AGX Thor 已用 ExLlamaV3 v1.5.1
运行全专家 EXL3 2.95 bpw 的 `DeepSeek-V4-Flash-0731`。32K 缓存配置、
10.4K token 输入均已生成正确结果；较长的两次解码实测约 15.4 tok/s。
另用包含 MTP 模块的 2.32 bpw 权重在同机启用 DSpark：单路 384-token
解码为 25.65 tok/s，同权重关闭 MTP 为 16.73 tok/s；这只是一次短输入对照。
该权重还完成了约 30K、60K token 的实际输入检索，以及 2 路、4 路短请求同时解码；
最长输入的冷预填充约需 5 分钟。
0731 是取代预览版的正式文本权重。[V4.1-Flash](https://www.deepseek.com/en/news/deepseek-v4-1-flash/)
是另一套 552B 架构；现在 DeepSeek API 的旧 V4 Flash 名称会路由至 V4.1，
不能把 0731 的本地结果用于 V4.1。

## 容量

[官方模型卡](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731)
给出的规模是 284B 总参数、13B 激活参数。MoE 推理仍需存放大量未激活专家，
13B 不能用于估计权重占用。Thor T5000 为 SM110、128 GB 统一内存，
CPU、GPU 和系统服务共享容量。

| 0731 权重路线 | 文件容量 | 单机判断 |
| --- | ---: | --- |
| [原生 MXFP4 GGUF](https://huggingface.co/antirez/deepseek-v4-gguf/tree/main) | 156 GB，约 145 GiB | 大于整机内存，不能完整常驻 |
| 同仓库 `ds4f-q2`，保留全部 256 专家 | 86.7 GB，约 80.8 GiB | 可常驻；仅 routed experts 的 gate/up 用 IQ2_XXS、down 用 Q2_K，其余关键张量保留较高精度 |
| 同仓库 `ds4f-q2-q4`，后六层专家升至 Q4 | 97.6 GB，约 90.9 GiB | 容量上可能；余量更小，启动和上下文待本机验证 |
| 同仓库匹配的 DSpark 辅助权重 | 5.99 GB，约 5.6 GiB | 可选，另占内存；推测解码收益依负载而变 |
| [完整专家 EXL3 优化版 2.95 bpw](https://huggingface.co/amanwalksdownthestreet/DeepSeek-V4-Flash-0731-exl3) | 本机文件 105.73 GB，约 98.47 GiB | 已在单 Thor 常驻并用 32K 缓存生成；最低可用内存约 15.6 GiB |
| [完整专家 EXL3 2.32 bpw，内含 MTP](https://huggingface.co/anoane/DeepSeek-V4-Flash-0731-exl3-2.32bpw) | 本机文件 90.94 GB，约 84.69 GiB | 已在单 Thor 上以 65,536 token 缓存完成约 60K 实际输入检索，并同时解码四个短请求；最低可用内存约 29.8 GiB |

文件大小见各权重仓库；ds4 的模型格式和下载名称见
[引擎说明](https://github.com/antirez/ds4)。文件大小只是内存下界，
还需留给 KV、CUDA 工作区和系统。标称 1M 上下文不等于单台 Thor
可在这个长度上可靠服务。现有生产推理通常占 70–90 GiB，
实验必须与生产实例互斥，运行时仍需遵守 12 GiB 可用内存红线。

## 单台 Thor 的外部实测

开发者在 [NVIDIA 论坛](https://forums.developer.nvidia.com/t/1x-spark-deepseek-v4-flash-0731-1-000-tok-s-prefill-59-tok-s-multi-agent-serving/378855/52)
报告 Thor SM110、Entrpi/ds4 v0.5.4、0731 IQ2XXS 权重及匹配 DSpark：
2.4K 输入时预填充 488 tok/s、解码 23–24 tok/s；63K 时为 431/22；
125K 时为 389/16.6；480K 时为 250/10.5。原先的 Top-512 CUDA
路径在 Thor 长上下文触发 Xid 13；作者改用有界 selector，并称
512K 配置需双请求 bank、4K 预填充分块及 8 GiB 内存底线。
[实现提交](https://github.com/pastoriomarco/NemoClaw-Thor/commit/7e1f590)
可供复现，但这些数字依赖该分支和设置，不能外推为本机吞吐。

另一个 [Thor 容器实践](https://github.com/vu2lid/ds4-thor-docker)
确认 Q2 可完整常驻，基础 ds4 约 8 tok/s、NVMe 专家流式读取约 1 tok/s。
它还记录当前实现主要服务单路请求，DSpark 在其配置上未带来稳定收益。
两份实测的运行时和工作负载不同，不宜直接比较速度；
但已足以修正“单台 Thor 完全无法运行”的判断。

## DGX Spark 的 EXL3 路线

[ExLlamaV3](https://github.com/turboderp-org/exllamav3) 的 EXL3
采用码本与 Trellis 量化，按张量分配精度，并支持 DeepSeek V4。
它需要对应推理内核，不能将 EXL3 权重当作 GGUF 直接交给 ds4 或 llama.cpp。
Spark 社区的
[单机方案](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark)
使用 REAP-K216 专家剪枝和 EXL3 3.0 bpw；
[权重说明](https://huggingface.co/0xSero/deepseek-v4-flash-0731-spark)
给出约 99.48 GiB 权重、启动时至少 114.3 GiB 可用内存；
即使移植成功，在 Thor 上也难维持现有的 12 GiB 内存余量。
该方案在单 Spark 上报告 38.12 tok/s 的五次代码解码中位数，
但量化、剪枝和 DSpark 同时参与，不能单独归功于 EXL3。
它依赖 GB10/SM121 的 [SparkInfer/b12x](https://github.com/local-inference-lab/b12x)
稀疏注意力和量化专家内核。此前审阅的
[`fdcd538` 版本](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark/tree/fdcd538fbf95fb15b2d6850db9613d22b2c889b8)
也明确指定 `CUTE_DSL_ARCH=sm_121a`。
仅修改架构标志不能证明它在 SM110 可运行。

下述 2.95 bpw 基线既没有 K216 专家剪枝，也没有 DSpark；
约 15.4 tok/s 的短请求解码与 Spark 的 38.12 tok/s 不是同一负载，
不能把差距或收益单独归因于量化格式。
此前厂商报告的[双机 Thor 约 70 tok/s](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/)
及产品页双机 Vision 数字，也不代表单台 0731 文本模型。

## 本机 EXL3 实测（2026-09-26）

使用 [全专家量化权重](https://huggingface.co/amanwalksdownthestreet/DeepSeek-V4-Flash-0731-exl3/tree/fcfe6bc6b432b3c035b207200f452b78b25010d6)
的 `2.95bpw-h16-opt` 分支、固定修订 `fcfe6bc6`。15 个 SafeTensors
文件共 105,734,808,962 字节，索引对应 135,966 个张量；权重不含
`mtp` 辅助头。运行时为 ExLlamaV3 v1.5.1（`958ec933`）、Torch 2.13
与 CUDA 13.0，在 SM110 上从源码编译。所需的
[ARM64 GPU 补丁](../engine/patches/exllamav3-v1.5.1-aarch64-gpu-only.patch)
排除了 x86 CPU 内核并提供桩；因此 CPU 专家卸载和 TP CPU reduce 不可用。
编译时设置 `TORCH_CUDA_ARCH_LIST=11.0`、`MAX_JOBS=4`，并用
`pip install --no-build-isolation` 安装源码。示例聊天脚本还需要
`pyperclip` 1.11.0。权重和实验镜像保留在 Thor 的
`/var/lib/thor-inference/exl3-0731` 与 `thor-exl3-chat:v151`，未设为常驻服务。

先停用生产实例，在单路 GPU 容器中用与[官方编码](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731/blob/main/encoding/encoding_dsv4.py)
相符的 `ds4` 提示格式、
温度 0、256 token 预填充分块测试。长输入使用 1 GiB 的循环状态检查点
缓存（`-rcs 1`）。表中速度来自 ExLlamaV3 的单次请求日志，内存为
主机 `MemAvailable` 的逐秒最低值。

| 缓存 | 输入 / 输出 token | 预填充 | 解码 | 结果及最低可用内存 |
| ---: | ---: | ---: | ---: | --- |
| 2K | 21 / 2 | 36.19 tok/s | 15.38 tok/s | `17×23 = 391`；输出太短，不代表持续速度 |
| 8K | 50 / 103 | 62.56 tok/s | 15.37 tok/s | 二分查找代码正确；约 16.7 GiB |
| 32K | 38 / 126 | 46.20 tok/s | 15.44 tok/s | 归并排序解释正确；约 15.6 GiB |
| 32K | 10,439 / 3 | 410.17 tok/s | 1.72 tok/s | 准确提取中间记录的 `731942`；约 15.6 GiB。3 token 解码速度无代表性 |

首次冷加载约 113.5 秒，随后热缓存加载约 24.6–25.0 秒；首次预热
11 轮耗时 21 秒。32K 是缓存容量设置，实际最长输入只验证到 10.4K
token。默认 4096 token 分块加载失败并报 `Insufficient VRAM in split`，
改用 256 后成功；把 `-rcs` 设为 0 则在长输入的循环状态检查点触发
`KeyError`。可复现的关键参数为
`-mode ds4 -cs 32768 -rcs 1 -chunk_size 256 -temp 0 -tps`。

实验容器在 12 GiB 可用内存下限处设了独立停止保护。现有生产
`memwatch` 的另一条规则在 `MemFree < 3 GiB` 且 `MemAvailable < 18 GiB`
时也曾留下运行时停止锁；实验结束、内存恢复后清锁并恢复生产服务。
这份结果仅证明单路生成和有限的短代码、算术、长文检索正确性；
并发、32K 实际输入、长时间运行及与原版模型的质量对照尚未验证。

## 本机 EXL3 + DSpark 实测（2026-09-26）

使用 [完整专家 2.32 bpw 量化](https://huggingface.co/anoane/DeepSeek-V4-Flash-0731-exl3-2.32bpw/tree/52ee0ca4b5e5d132a1b4e91d11824c6943cba1f7)，固定修订 `52ee0ca4`。
12 个 SafeTensors 文件共 90,939,355,279 字节；索引含 9,447 个 `mtp.*`
张量，其中三个 DSpark block 在同一包内。量化作者在 ANEMONE 分支验证过，
但未声称 stock ExLlamaV3 兼容。本机沿用上节的 patched v1.5.1、
Torch 2.13、CUDA 13.0、SM110 镜像，成功用 `-mtp` 加载并生成。
测试时只为记录分配错误和草稿加载占用临时加入日志；推理计算路径未改。

停用生产实例后，每行由独立容器运行相同的归并排序提示词：47-token 输入、
温度 0、最多 384-token 输出、`-mode ds4 -cq 8 -rcs 1 -chunk_size 256`
及 118 GiB 容器内存上限。输出均达到 384-token 截断，故速度覆盖持续解码，
答案完整性不能由这组截断输出判断。`-cq 8` 是缓存配置参数，
不意味着所有 DSA／DSpark 缓存均为 8-bit。`MemAvailable` 为主机逐秒最低值。

| 缓存配置 | MTP | 预填充 | 384-token 解码 | 草稿接受 | 最低可用内存 |
| ---: | :---: | ---: | ---: | ---: | ---: |
| 8K | 关 | 71.55 tok/s | 16.73 tok/s | — | 35.52 GiB |
| 8K | 开 | 48.53 tok/s | 25.65 tok/s | 296 / 352，84.09% | 30.40 GiB |
| 32K | 开 | 49.30 tok/s | 25.78 tok/s | 296 / 352，84.09% | 30.19 GiB |

8K 的 MTP 开关对照中，解码速度增加约 53.3%；47-token 短输入的预填充
则从 71.55 降至 48.53 tok/s。这是单个提示词、单次运行，不能代表一般负载。
MTP 两次输出相同；与无 MTP 输出有一处措辞差异，不能宣称逐 token 等价。
该行的 32K 是缓存容量配置，实际输入仍只有 47 token。加载日志显示主模型加 MTP
约 90.92 GB、无 MTP 约 85.75 GB，差约 5.18 GB。

容器上限设为 110 GiB 时，主模型 32K／8K 加载曾报
`Insufficient VRAM in split for model and cache`，另一次 8K 加载成功。
8K MTP 在第 42 层失败时，PyTorch 单进程预算约 84.19 GiB、GPU 物理空闲
约 28.85 GiB；这不是主机物理内存耗尽。把容器上限调至 118 GiB 后，
上述三轮均成功，最低主机可用内存仍高于 30 GiB。12 GiB 实验保护未触发。
实验结束已移除临时诊断脚本，恢复生产服务并确认 `/health` 返回 200；
权重与结果日志保留在 Thor 的 `/var/lib/thor-inference/exl3-0731-dspark-232`
及 `exl3-0731-dspark-232-results`。

### 实际上下文与并发

继续使用同一权重、镜像、`-mtp -cq 8 -rcs 1 -chunk_size 256 -temp 0`
和 118 GiB 容器上限。长输入检索把唯一的 `TARGET` 放在合成档案中段；
两次请求都无前缀缓存命中，且准确返回 `731942`。预填充时间不含模型加载，
输出仅 3 token，不能由此估计长上下文解码速度。结果来自不同的独立进程：

| 实际输入 | 缓存容量 | 冷预填充 | 最低可用内存 | 结果 |
| ---: | ---: | ---: | ---: | --- |
| 29,998 token | 32,768 token | 152.97 秒 | 30.22 GiB | 中段目标正确 |
| 59,986 token | 65,536 token | 301.98 秒 | 29.82 GiB | 中段目标正确 |

用 32K **共享**缓存分别运行 2 路、4 路短代码请求。每路输入 32–37 token，
最多生成 192 token；`-ambs` 与 `Generator.max_batch_size` 均设为对应路数。
观察到的活跃请求峰值分别为 2 和 4，生成器有多路同轮输出，所有请求都达到
192-token 上限：

| 活跃请求 | 合计输出 | 整轮耗时 | 合计生成速度 | 最低可用内存 |
| ---: | ---: | ---: | ---: | ---: |
| 2 | 384 token | 36.12 秒 | 10.63 tok/s | 30.01 GiB |
| 4 | 768 token | 43.54 秒 | 17.64 tok/s | 29.79 GiB |

这些结果证明四路短请求可同时解码，截断的代码不构成正确性验证。各轮的提示词、
输出长度与上表单路 384-token 对照不同，不能据此计算并发加速比。
共享缓存容量须覆盖所有活跃请求的 token 总量，加上生成预算；
四路 60K 或完整 256K 输入、排队、公平性、请求取消和长期服务均未测试。
本轮实验用 18 GiB 主机可用内存保护；结束后已恢复生产服务并确认健康检查通过。
复现脚本保留在 Thor 的 `exl3-0731-dspark-232-results/capacity-probe.py`。

### 借鉴现有 Qwen3.8 服务

[Thor 生产配置与验证记录](../thor-inference.md)把单请求上下文、所有活跃请求共用的
token 池、请求槽位和输出预留分别约束。Qwen3.8 设置为 262,144 token 单请求、
270,336 token 共享池、最多四个活跃请求；客户端通常最多提交 253,952 token
输入，为输出预留 8,192 token。该服务实测过 261,120-token 单路检索和四路约
32K 独立检索，尚未验证四路完整 256K。DeepSeek 的 ExLlamaV3 缓存也应按
`单请求输入 + 输出` 与 `同时活跃请求的总 token` 分开预算；目前只能据上述
60K 单路和四路短请求实测设定保守限额，不能沿用 Qwen 的 256K／四路声明。

Qwen 的可复用运维模式还包括有界预填充分块、长输入首 token 延迟测试、
取消后释放资源、服务健康检查、超时、可用内存保护和失败后恢复生产。
DeepSeek 的 60K 冷预填充已约 302 秒，API 客户端超时必须覆盖加载、排队和预填充。
可以在相同提示词下调整 ExLlamaV3 的 256-token 分块、DSpark 草稿长度与
动态草稿策略，并比较单路及多路的吞吐、延迟和内存。Qwen 专用的 Mamba
槽位数、DFlash 与 CUDA graph 参数不能直接搬到 ExLlamaV3。

## 下一步

用同一组实际提示词对照 MTP 开关及 1／2／4 路吞吐，再测试 128K、256K
实际输入与并发长输入的共享缓存、首 token 延迟和答案质量。
接入 API 前还需验证流式响应、取消请求后的资源回收、超时与健康检查；
再与 2.95 bpw EXL3、GGUF Q2 + ds4 比较质量与性能。
生产实例与本模型必须互斥；若要长期服务，还需把内存锁恢复流程和
负载测试纳入部署配置。
