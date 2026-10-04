# Qwen3.8 Flash Next：NVFP4、CUDA Graph 与 MTP

[Thor 概览](../../README.md) ·
[Lazycat 官方应用部署](../../../../../inventory/guanggu/lcmd/thor-apps/qwen3.8-flash-next.md)

源码审查：部署修订版 `d03809008834124e80223c3482f2ddb59577a48f`。
本地启动与性能实验：2026-09-13。

## 检查点与内存布局

在保留桌面环境的前提下，Qwen3.8 Flash Next 是更切实可行的下一个候选模型。
其约 99 GiB 的检查点包含一张 26.82 GiB 的 PLE 表，因此常驻 GPU 的权重约为
72 GiB。额外的打包 PLE 文件是由 CPU worker 映射的磁盘副本，并非必须始终
常驻的另外 27 GiB。该部署默认预留 26 GiB 主机内存；PLE 页缓存、桌面进程和
驱动程序分配共同使用这部分预留。在 Thor 上尚未验证其宣称的完整上下文长度和并发能力。

## 运行时与算子兼容性

固定使用的 ARM64 镜像为
`vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e`。
本地容器探测显示版本为 Torch 2.13.0+cu130、vLLM
`0.1.dev20073+g8e685d198`、FlashInfer 0.6.17、Triton 3.7.1 和 CUTLASS DSL 4.6.2。
Torch 包含 SM110 支持，并在 Thor 上通过了小规模 BF16 CUDA 矩阵乘法测试。
在禁用网络的条件下还进行了以下小张量探测：

| 路径 | 观测结果 |
| --- | --- |
| GDN 打包解码，BF16 状态/输出 | 通过单 token 零状态参考测试；最大绝对误差 0.0000529 |
| MXFP8 FlashInfer CUTLASS GEMM | 与 BF16 参考值的随机矩阵比较：余弦相似度 0.999285 |
| NVFP4 FlashInfer CUTLASS MoE | 两个使用非零常量权重的小型专家：输出约为 93.6 时最大绝对误差为 2.5 |
| QSA BF16 评分和稀疏注意力 | 参考误差约为 0.00000191 和 0.000551 |
| QSA 默认 cooperative top-k | 在 SM110 上因 CUDA cluster 配置错误而失败 |

QSA 调度器会为 SM120 系列之外、计算能力 >=90 的设备选择 cooperative top-k，
因此 Thor 也会选中该路径。镜像中已有的 persistent top-k 实现可以成功执行。
通过临时 bind mount 补丁将 SM110 系列排除在 cooperative 分支之外后，完整的
selector 调用也通过了测试。后续测试从 1024 个可见候选项中选取 512 个，其索引集
与 `torch.topk` 一致，且截断点处没有相同值；之后的注意力计算最大绝对误差为
0.000515。这是一项兼容性规避措施，并非模型吞吐量结果；未经修改的镜像仍会走入
这个失败的默认路径。

后续测试将仓库中的 FP8 KV 补丁与 SM110 selector 修复结合起来。使用非单位 K/V
scale 时，原生 FP8 缓存和以 uint8 为底层存储的缓存均通过了与显式反量化参考值的
对比。从 1024 个候选项中选取 512 个的测试也通过了。selector 与注意力各自的
CUDA Graph 在三次 replay 中持续保持正确，期间 query、KV 和 scale 都进行了
原地修改；注意力的最大绝对误差低于 0.000648。这项检查比较的是相同量化输入下的
实现结果，而不是相对于 BF16 权重或缓存的模型质量。

固定在 `925d7be6c14c6c9442ef83e8f05b5a3c39304f69` 的检查点对 48 个主路由专家层
使用 NVFP4 W4A4。W4A16 NVFP4 用于 MTP 专家和 27 个视觉投影。在此镜像中，
SM110 上的自动 MoE 选择为主专家选用 **vLLM CUTLASS**，为 MTP 选用 **Marlin**。
FlashInfer CUTLASS 是另一个后端，vLLM selector 明确将其排除在 SM110 之外；
之前对该后端的原语探测不得表述为模型级覆盖。应保留自动选择，使两种量化方案可以
选择不同后端。

采用实际形状的原语探测使用了 512 个专家、2560 的 hidden size、640 的
intermediate size 和 top-k 10，并分别测试一个和八个输入 token。vLLM CUTLASS
W4A4 路径产生了非零输出，与理想 BF16 常量权重参考值的偏差在 4% 以内。
Marlin 先进行真实权重重打包和 scale 转换，再执行 W4A16，其结果与自身可表示的
常量参考值一致。在这个单层测试中，Marlin 转换的 Torch 内存峰值为 5.91 GiB，
加载时必须为此留出空间。这些是受控算子检查，不是对真实检查点质量、模型路由或
MTP 接受率的测量。

## 检查点加载与 padding 故障

完整检查点已成功下载（约 98.57 GiB），其中 26.82 GiB 的打包 PLE 表通过了
元数据和大小检查。三次完整启动尝试都加载了权重（vLLM 报告为 70.83 GiB）并挂接
PLE CPU worker，但均未启动出健康的 API。这些尝试使用 BF16 KV、4096-token
上下文、512-token prefill 上限、一个序列、不启用 MTP 且不启用 CUDA Graph。
前两次在 dummy profiling 阶段失败，原生 CUTLASS MoE 路径发生 CUDA 非法内存
访问。第三次加入 instrumentation 的运行在进入 MoE 时成功完成同步，并发现
512×10 个专家 ID 全部等于 `-1`，激活值为有限的零，路由权重均匀。一次 assertion
在生成元数据前中止了该运行。检查精确镜像的源码后发现，V2 dummy batch 会将每个
token 都标记为 padding，而 `VLLM_MOE_SKIP_PADDING=1`（默认值）会把这个 mask
传给 router。一项小规模 router A/B 测试复现了默认设置下全部 ID 为 `-1` 的情况；
使用 `VLLM_MOE_SKIP_PADDING=0` 时则得到有效 ID。在混合 batch 中，真实 token 的
专家 ID 和权重保持完全相同。第四次完整启动禁用这项优化后，通过了元数据生成、
行重排、激活量化以及两次 MoE GEMM，随后进入 KV cache 初始化。这项规避措施会
计算 padding token，而不是改写无效 ID。这不能证明 SM110 无法执行 NVFP4。
独立的 512-token 探测中，分散路由以及集中到十个专家的路由均通过测试。采用真实
形状的 GDN prefill 探测也通过了受控参考测试。

## 内存分配停滞

第一次加载发出了可恢复的 NVIDIA 分配警告；第二次在没有这些警告的情况下复现了
CUDA 故障。加载期间，Linux 在内存压力下回收了文件缓存。没有观察到内核 OOM kill，
也尚未证实仅由内存压力导致 CUDA 故障。第四次运行给 KV 分配 9.18 GiB 后出现了
另一次独立的分配停滞：实时 worker 栈显示 NVIDIA 系统页分配停在 direct compaction
和 page migration 中。尽管约有 33 GiB 空闲内存，Normal zone 中却没有 order 9
或更高阶的空闲 buddy block（在此 4 KiB 页内核上为 2 MiB）。Cgroup OOM 和限额
计数器均为零。停止容器后恢复了高阶空闲块。第五次试验明确将 KV 限制为 1 GiB，
保留 4096-token 上下文，并移除了同步 CUDA 调试和诊断 instrumentation。它为
14,199 个 KV token 分配了容量，完成 warmup 并提供了健康的 API。这避免了已观察到的
分配停滞，但并非证明 KV 大小是唯一促成因素的受控实验。

## Eager 生成基线

最初的顺序 smoke request 生成了连贯的中文（101 个输出 token）、Python 代码
（256 个 token，受请求上限截断）和完全符合要求的 JSON 对象（20 个 token）。
解码速率为 5.90–6.01 tokens/s；首次内容出现时间分别为 2.41、2.09 和 0.41 秒。
第一次请求触发了 QSA JIT 编译。这些是使用 BF16 KV、单请求、不启用 CUDA Graph
且不启用 MTP 的简短功能探测，并非调优后基准测试的中位数。此处解码速率为
`(completion_tokens - 1) / (stream_end - first_content)`。

warm repeat 将代码输出上限提高到 512 个 token。三个请求均正常结束：中文输出
108 个 token，速率 5.99 tokens/s；代码输出 341 个，速率 5.99；JSON 输出 20 个，
速率 5.92。首次内容延迟分别为 0.44、0.55 和 0.61 秒。完整 Python 响应成功通过
解析，并包含三个 assertion（未执行）；尽管 prompt 要求仅输出代码，它仍使用了
Markdown fence。JSON 再次与要求的对象完全一致。这证明了基本文本生成能力，不代表
通用质量评估结果，也不代表严格通过指令遵循测试。

## 基线启动配置

可工作的基线保留了上游 PLE mmap/CPU-offload 和 MXFP8 补丁、Thor QSA selector
规避措施，以及 `VLLM_USE_V2_MODEL_RUNNER=1`、`VLLM_PLE_CPU_OFFLOAD=1` 和
`VLLM_MOE_SKIP_PADDING=0`。其主要服务参数如下：

```sh
--tensor-parallel-size 1 --distributed-executor-backend mp \
--kv-cache-memory-bytes 1073741824 --max-model-len 4096 \
--max-num-seqs 1 --max-num-batched-tokens 512 \
--kv-cache-dtype bfloat16 --mamba-ssm-cache-dtype bfloat16 \
--load-format safetensors --safetensors-load-strategy lazy \
--enable-chunked-prefill \
--compilation-config '{"mode":0,"cudagraph_mode":"NONE"}'
```

## Decode CUDA Graph 对比

一项独立的 decode graph 后续测试仅将编译配置改为
`{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1]}`。
镜像在约三秒内捕获了一张 graph，占用 0.12 GiB；prefill 仍使用 eager，Torch 编译
仍保持禁用。中文、完整 Python 和精确 JSON 的 smoke response 均成功。另行完成一次
32-token warmup 后，对同一个中文 prompt 顺序执行三次 128-token 生成，测得：

| 配置 | 解码速率（tokens/s） | 中位数 |
| --- | --- | --- |
| Eager，BF16 KV | 6.03, 6.08, 6.18 | 6.08 |
| Decode graph，BF16 KV | 26.31, 26.29, 26.41 | 26.31 |

对于这个短时单流 workload，性能提升为 4.32 倍，MTP 仍处于禁用状态。请求使用零
temperature 和 `ignore_eos=true` 来固定输出长度；两次运行均保持 prefix caching
启用。两者的首次内容延迟中位数均约为 0.41 秒。不同的 smoke prompt 产生了相应的
不同响应，但没有断言输出完全等价。此镜像中的 V2 没有内置 replay 计数器；日志记录了
capture，但尚未采集 replay 的 profiler trace。

## MTP：缺失 GDN kernel 与定向 fallback

最初的 MTP 试验保留 BF16 KV 和完整词表，设置 `num_speculative_tokens=1`，graph
capture size 为 `[2]`。自动选择为 target 使用原生 CUTLASS，为 W4A16 draft 使用
Marlin。两个模型均已加载（总计报告为 72.36 GiB），但 warmup 在
`fused_gdn_decode_post_conv_mtp` 处报错 `no kernel image is available for execution
on the device`。这是一条独立的多 token GDN 路径，并非此前成功的普通 decode
路径。镜像的 dispatch guard 检查计算能力 >=80 以及算子是否存在，这不足以证明
Thor 的二进制覆盖。对精确库执行 `cuobjdump` 后确认，该 kernel 仅存在于
SM80/86/89/90a/100f/120f 代码中，没有 SM110/110f 版本或匹配的 PTX entry。同一库中
的其他 kernel 确实包含 SM110/110f。在 `_can_use_fused_gdn_mtp_decode` 中添加
`and not current_platform.is_device_capability_family(110)` 后，
会仅在 Thor 上选择现有的 speculative Triton/FLA 路径；若全局强制设置
`VLLM_GDN_DECODE_KERNEL=triton`，也会改变普通的单 token decode。一项采用实际 head
形状的双 token 探测，在 eager 和 graph 模式下，对照 Torch 参考实现通过了卷积、
递归状态更新和 gated RMS normalization 测试。BF16 normalization 后的输出最大误差
为 0.00768，每个 token 的状态误差最多为 0.000244。使用不同输入的 Graph replay
也通过了测试。后续测试使用非零历史和一、二两个 accepted-token count，在 eager 与
graph 模式下检查了不同先前状态的选择、卷积 buffer 的精确滑动更新，以及 null slot
保持不变。这些测试使用有效的 state slot（slot zero 已预留）。

## MTP K1：完整模型结果

定向 guard 随后通过了完整模型的 MTP 启动和 graph capture。在启用 MTP 时，同样的
1 GiB KV 预算可提供 10,132 个 token。保留完整 draft 词表、K1 和 capture size `[2]`
后，同一项固定长度基准测试测得 **32.23、32.79 和 33.59 tokens/s**，中位数为
**32.79**。这比非 speculative graph 基线高 24.6%，是原始 eager 基线的 5.39 倍。
首次内容延迟中位数为 0.47 秒。包含一次 32-token warmup 和三次 128-token 请求的
Prometheus 计数器增量显示，245 个 proposed token 中有 170 个被接受（69.4%）；
这个接受率包含 warmup，而报告的耗时中位数不包含 warmup。

warm functional check 生成了连贯的中文，速率为 32.99 tokens/s；完整 Python 的
速率为 38.24；精确 JSON 为 37.35。Python 成功通过解析并包含三个 assertion，但未
执行。速率会随生成内容和 draft 接受率变化。完整模型输出等价性、长上下文质量和
多模态 MTP 仍未经验证。这个可工作的实验在 BF16 基线之上加入定向 GDN guard 和
以下参数：

```sh
--speculative-config '{"method":"mtp","num_speculative_tokens":1}' \
--compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[2]}'
```

## MTP K3：与 K1 对比

在完整模型试验前，GDN fallback 探测被扩展到四个 token，并使用非零历史测试
accepted-token count 1–4。全部八种 eager/graph 情况均通过输出、逐 token 状态和
精确卷积 buffer 回写检查。tensor 分配峰值为 67.26 MiB。随后，K3 使用相同的 SM110
guard、BF16 KV 和完整词表成功加载并提供服务：

```sh
--speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
--compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,4]}'
```

Capture size 4 覆盖 target verification/first draft；size 1 覆盖后续的单 token
draft step。日志确认捕获了 target 和两个 speculator。模型加载报告仍为 72.36 GiB，
而 1 GiB KV 预算提供了 7,404 个 token，足以满足配置的 4096-token 单请求。

2026-09-13 的 K3 运行之前紧接着进行了一轮新的 K1 测试。每种 workload 都使用各自的
warmup（文章/代码为 32 个 token，JSON 为一个完整响应），然后顺序执行三个计量请求。
prefix caching 保持启用，temperature 为零，并禁用 thinking。文章/代码使用
`ignore_eos=true`；JSON 采用普通停止条件，上限为 80 个 token。固定长度和 JSON 值均
经过验证。精确 prompt 如下（保留实验输入原文）：

| 工作负载 | 输出 token 数 | 提示词 |
| --- | ---: | --- |
| 中文 | 128 | 请写一篇详细的科普文章，解释地球水循环如何连接海洋、大气、陆地和地下水，并讨论人类活动的影响。 |
| 代码 | 256 | 原文（保留实验输入）：Write a Python function that merges overlapping integer intervals. Include type hints and three assert examples. Output only code.<br>中文：编写一个合并重叠整数区间的 Python 函数。包含类型提示和三个 assert 示例。仅输出代码。 |
| JSON | 20 | 仅输出一个JSON对象，包含city值北京，country值中国，number值42，不要Markdown。 |

| 工作负载 | K1 解码速率 | K3 解码速率 | 中位数变化 |
| --- | --- | --- | --- |
| 中文 | 33.91, 33.83, 33.99 | 31.39, 31.79, 31.74 | 33.91 → 31.74 tokens/s（−6.4%） |
| 代码 | 38.96, 38.65, 38.27 | 52.72, 53.60, 53.61 | 38.65 → 53.60 tokens/s（+38.7%） |
| JSON | 37.17, 36.93, 36.90 | 45.21, 45.12, 45.74 | 36.93 → 45.21 tokens/s（+22.4%） |

中文/代码/JSON 的首次内容延迟中位数在 K1 下为 0.463/0.492/0.481 秒，在 K3 下为
0.484/0.491/0.517 秒。全文始终使用同一种流式解码估算方法；短 JSON 的计时不是持续
吞吐量基准。排除 warmup 后，每组三个请求的 Prometheus 增量如下：

| 工作负载 | K1 已接受/已提出 | K3 已接受/已提出 | 平均接受长度，K1 → K3 |
| --- | --- | --- | --- |
| 中文 | 159/225（70.7%） | 213/522（40.8%） | 1.71 → 2.22 |
| 代码 | 372/393（94.7%） | 561/612（91.7%） | 1.95 → 3.75 |
| JSON | 30/30（100%） | 48/54（88.9%） | 2.00 → 3.67 |

平均接受长度为 `1 + accepted_tokens / draft_steps`，其中包含 bonus token。proposal
计数可能包括超过请求停止边界的 token；它与实际交付的输出 token 数并不相同。这些
结果支持在所测代码 workload 上使用 K3，而对于这个文章 prompt，K1 更快。它们不能
证明存在普遍最优的设置，也没有把接受率影响与生成文本变化隔离开来。

另一次 warm functional pass 生成了完整 Python（277 个 token，53.54 tokens/s），
成功通过解析并包含三个 assertion（未执行）。中文连贯，JSON 与要求的对象完全一致。
实验服务最终保持运行 K3；可工作的 K1 配置和两组原始结果均保存在公开仓库之外。

## 确定性 QSA 选择：正确性回归

2026-09-13，合成输入在这台 Thor 上复现了错误的 `persistent_topk` 选择。当 `k=512`
时，从窄分布（均值 10、标准差 0.03）抽取的 64 行、每行 4096 个 float32 score，在
全部十次重复中都选出了严格小于精确 top-k 的值。选中值的最大误差为 0.0396233。
一个 33 行、32768 列的案例也失败了。这些是数值错误，不同于在 score 相等时选择了
不同索引。所有受测形状在重复调用时都会改变输出顺序；截断点存在相同值的案例还会
改变选中的索引集。这不能证明之前的模型响应有误。

来自 [jschmied 固定源码](https://github.com/jschmied/qwen38-flash-next-gb10/tree/e0ef69d4f5575dad00d34e05479eaf4c6547bace/patches/kernel-det)
的独立确定性 kernel，在现有 Torch 2.13.0 / CUDA 13.0 镜像中针对 `sm_110a` 完成
构建。源码 hash 已与 [Saren 构建方案](https://github.com/Saren-Arterius/qwen3.8-Flash-DGX-AutoRound)
核对。仅修改了 SM110 QSA selector dispatch；保留现有 attention/scale 接口、模型
权重和 GDN fallback。

验证通过：

- 二十种形状/分布案例，每种重复十次：选中值精确、索引有效且唯一、输出顺序稳定、
  索引集稳定。
- 六种 CUDA Graph 形状，`k=512/1024/2048`，可见长度不断变化，其中包括短序列和
  空序列。
- 集成式 QSA 评分、选择和稀疏注意力参考检查。
- 一个 2823-token retrieval prompt 在连续三个请求中返回了完全符合要求的 JSON，
  其中包括 prefix reuse。这是一项定向回归测试，而非广泛的长上下文质量评估。

采用上述相同的 K3 workload/warmup 流程，三次运行的中位数如下：

| 工作负载 | 修复前 | 确定性 selector |
| --- | ---: | ---: |
| 中文 | 31.74 | 32.02 tokens/s |
| 代码 | 53.60 | 54.21 tokens/s |
| JSON | 45.21 | 45.53 tokens/s |

全部九个计量响应文本都与上一次运行完全相同；JSON 正确。微小的计时差异不足以证明
性能提升。这是一项正确性改进，实测吞吐量大体不变。实验服务现已使用确定性 selector；
此前的启动配置仍可用于回滚。

相关上游报告：
[persistent_topk 候选项丢失 #51782](https://github.com/vllm-project/vllm/issues/51782)
和[确定性选择 PR #55122](https://github.com/vllm-project/vllm/pull/55122)。

## 官方 Thor 镜像：初始化内存

测试了 [NVIDIA Thor 方案](https://www.jetson-ai-lab.com/models/qwen3-8-flash-next/)，
镜像 digest 为
`sha256:512bf772c7ef221df1a66ab9c95546d77daeba6ba61723692852e6eb0cae7526`。
它的打包 NVFP4 PLE 表驻留在 GPU 上；现有实验运行时使用 CPU mmap/offload。该方案
`local-inference-lab/Qwen3.8-Flash-Next-NVFP4` 修订版
`ada4da32a583a78aa47299f45a70603c950490b8` 中的全部 37 个 safetensors 文件，
其 SHA-256 和大小均与现有 Mia 检查点一致，因此测试复用了这些权重。

三次初始化尝试均保留 4096-token 上下文、1 GiB BF16 KV、BF16 Mamba 状态、一个请求
和 K3 MTP。这些初步探测使用 eager 模式。在健康 API 可用前，实验性内存 watchdog
便将其停止；因此没有得到官方镜像的吞吐量结果。

- 第一次尝试在加载 PLE 时越过低空闲内存 guard。
- 仅文本加载，并对只读检查点文件应用 `POSIX_FADV_DONTNEED` advice，降低了可回收
  文件缓存的压力。它最终到达模型加载报告的 98.4 GiB，但可用主机内存低于保留的
  12 GiB 余量，watchdog 因此将其停止。
- 第三次尝试在 target 与 MTP 加载之间增加了 GC 和 CUDA cache 释放。当时 target
  已分配/预留的内存没有变化，可用内存 guard 仍然停止了初始化。

三次尝试均报告 `OOMKilled=false`；watchdog 终止不能证明发生了 CUDA 或内核 OOM，
也不能证明官方配置无法装入。第二次尝试记录到一次 NVIDIA 内存错误，第一次和第三次
均无此错误。官方镜像尚未满足本实验的内存余量要求。其源码已经共享 target/draft
token embedding 和输出 head；仅有不同模型路径不能证明存在重复常驻权重。

## 原生 SM110 GDN MTP 移植

官方镜像 vLLM 修订版 `385dce36b` 中的原生 GDN MTP kernel，在现有 CPU-offload
运行时中被构建为单独的 `sm_110f` 扩展。仅改变了 MTP GDN dispatch；确定性 QSA、
权重、打包 CPU PLE、BF16 cache 和 K3 设置均予以保留。服务日志确认原生 kernel
得到执行，且 CUDA Graph capture 成功。模型加载报告仍为 72.36 GiB。

该扩展对照随附的 FLA/RMSNorm 参考实现通过了 32 个定向案例：包括 eager 与
CUDA Graph 执行、两种受支持的 gate activation、不断变化的输入，以及从一到四的
accepted-token history 序列。输出相对 L2 误差始终低于 `5e-4`；状态检查使用
`atol=rtol=0.03`。这些是基于容差的检查，不代表 bitwise 等价，也不构成模型质量认证。

采用相同的三次运行 K3 流程，结果如下：

| 工作负载 | FLA fallback + 确定性 QSA | 原生 GDN + 确定性 QSA |
| --- | ---: | ---: |
| 中文 | 32.02 | 33.56 tokens/s |
| 代码 | 54.21 | 54.92 tokens/s |
| JSON | 45.53 | 45.73 tokens/s |

不同实现下的中文和代码响应文本有所变化，但每种实现自身的三次计量重复都保持稳定。
JSON 保持相同且正确。因此，上述小幅差异并未隔离出 kernel 速度：生成的 token 和
speculative 接受率也可能发生变化。这没有复现出显著的端到端收益。使用原生 kernel
时，2823-token retrieval 检查也通过了三次。采用正常 EOS 处理的代码 smoke test
在 512-token 预算内完成；其中三个 assertion 以及另外三个空区间/未排序/负数区间检查
均通过。这项小型 smoke test 不能衡量通用编程质量。实验服务现已使用原生扩展，同时
保留 FLA 启动配置以供回滚。

## 启用 Graph 的性能分析

原生 GDN 运行时启用按需 Torch profiling 后重新启动，并保留 K3 和 CUDA Graph。
重复基线测试期间关闭 sampling：中文为 33.92、代码为 56.19、JSON 为
45.77 tokens/s；全部九个计量文本都与上一次原生 GDN 运行一致。这些微小的计时变化
不足以证明性能提升。

中文与代码各自的独立 trace 都包含一次 context iteration 和九次 decode iteration。
尽管配置了延迟两个 iteration，它仍未排除 context iteration；分析采用观测到的边界。
根据每条 trace 中的 38 次 `cudaGraphLaunch` 调用、graph ID 及 launch correlation，
确认实际发生了 Graph replay。仅凭 CPU annotation duration 无法覆盖完整的异步
sampling/drafting 周期。

| 观测到的解码组件 | 中文 | 代码 |
| --- | ---: | ---: |
| Target Graph GPU 时间跨度，9 次中位数 | 42.67 ms | 41.74 ms |
| 三个 draft Graph 时间跨度之和，9 次中位数 | 17.73 ms | 17.70 ms |
| Target 开始至最终 draft 完成，9 次中位数 | 65.41 ms | 64.94 ms |
| 连续 target 开始间隔，8 次中位数 | 72.12 ms | 73.53 ms |

完整词表 head 仍为 BF16，形状为 `[248320,2560]`。针对该精确形状的独立合成权重
探测测得：一行为约 4.75 ms，四行为约 4.77 ms。它识别出的 cuBLAS kernel 为
`nvjet_sm110_tst_128x8_64x12_2x1_v_bz_TNT`，grid 为 `[1940,1,1]`。同名但 grid
更小的 kernel 也出现在其他层中。同时匹配名称与
grid 后发现，每个 captured iteration 恰好有四次 head projection，合计平均约
19.1–19.2 ms。其中三次已包含在上述 draft Graph 时间跨度内；再次相加会重复计时。
36 个原生 GDN kernel 合计在每次 decode iteration 中耗时约 1.10 ms。这表明在此
配置下，完整词表 head 是远大于 GDN 的剩余开销。它不能证明量化 head 替代方案的
速度或质量。

当前挂载的 PLE 补丁会在 replay 前让主机等待 CPU worker 完成 H2D copy。其 GPU wait
wrapper 不执行任何操作。主 worker 的 Torch profiler 无法捕获 CPU worker，因此这些
trace 没有隔离出 PLE lookup 或主机等待时间。剩余间隙还包含 scheduling、launch 和
profiler overhead；不能将其全部归因于 PLE。同样，target kernel 会跨 stream 重叠，
因此 kernel 时间之和可能超过 Graph 的实际时间跨度。

capture 后已停止 profiling，API 仍保持健康。原始 trace 保存在 Git 之外。缩减词表的
drafting 仍处于禁用状态；这些结果没有改变其尚未验证的语言覆盖率与接受率权衡。

## 完整词表 head 量化探测

使用合成 hidden state 对检查点的真实 BF16 head 进行了独立测试。计时包含动态激活
量化和输出 rescale，但不包含一次性权重转换：

| 投影 | 一行 | 四行 |
| --- | ---: | ---: |
| BF16 | 4.76 ms | 4.76 ms |
| 使用逐行权重/激活 scale 的 FP8 | 2.46 ms | 2.51 ms |
| 使用逐行权重和逐 token 激活的 INT8 | 2.68 ms | 2.81 ms |

受测 PyTorch INT8 API 要求输入超过 16 行，因此将小 batch padding 到 32 行，并丢弃
额外结果。INT32 累加结果 rescale 为 BF16。FP8 和 INT8 路径均通过了输入 buffer
不断变化的 CUDA Graph replay 检查。

对于 32 个相同的合成 hidden vector，FP8 逐行 scale logit 的相对 L2 误差为 0.0374，
其中 31/32 行的 argmax 与 BF16 一致；INT8 的相对 L2 误差为 0.0131，32/32 行均
一致。这些是算子探测，不是实际请求的质量测量。观测到的 INT8 误差更小，因此启动了
第一次 serving 实验；这不能证明它普遍优于 FP8。

### 仅 Draft 的 INT8 服务结果

仅替换 draft 模型的 `LogitsProcessor._apply_head`，同时覆盖完整 logit 和
`get_top_tokens` 路径。它保留全部 248320 个词表项，并保持共享 BF16 权重和 target
projection 不变。draft processor 拥有一份单独的 INT8 副本，在 Graph capture 前
初始化。这会增加约 0.6 GiB 权重存储，而不是降低模型常驻内存。独立 processor 检查
覆盖了完整词表 forward/argmax、零输入和 buffer 变化的 Graph replay；服务启动确认
量化 draft 路径生效且 Graph capture 成功。

采用相同的 K3 流程，每种 workload 进行三次计量运行并关闭 profiling，结果如下：

| 工作负载 | 最新 BF16-head 基线 | 仅 Draft 的 INT8 | 变化 |
| --- | ---: | ---: | ---: |
| 中文 | 33.92 tokens/s | 35.75 tokens/s | +5.4% |
| 代码 | 56.19 tokens/s | 61.44 tokens/s | +9.3% |
| JSON | 45.77 tokens/s | 50.69 tokens/s | +10.8% |

代码和 JSON 文本与基线一致，draft-token 接受率保持 95.45% 和 88.89% 不变。中文文本
发生变化，接受率从 44.24% 降至 42.69%；因此其速度差异并非输出严格相同的对比。每种
workload 的三次 INT8 运行均产生稳定文本。将 target projection 保持为 BF16，并未让
所有生成文本在 draft 路径改变时都保持 bitwise 不变；本实验没有确定中文轨迹为何发生
分歧。

2823-token retrieval 检查通过三次。一个完整代码响应通过了自身的三个 assertion 和
另外三个区间检查，JSON 仍保持正确。这些定向检查不构成广泛质量评估。实验服务现已
使用仅 draft INT8，同时保留 BF16-head/原生 GDN launcher 以供回滚；API 保持健康。

### W8A16 后续测试

在同一个完整词表上测试了 group size 128 的 Marlin 对称 INT8 权重和 BF16 激活。
真实 head 按有界列分块进行打包；它通过了与 helper 反量化参考值的比较，以及输入变化/
零输入的 Graph replay。独立 projection 的中位数在一行和四行情况下均为 2.47 ms。

在一组新对齐的 32 个合成 hidden vector 上，W8A16 的相对 logit L2 误差为 0.00797，
W8A8 则为 0.01317；两者均有 31/32 行的 argmax 与 BF16 一致。这些输入与之前的探测
不同，因此不能将其 argmax 数量与本组直接比较。

仅 draft W8A16 服务保留 BF16 target，结果如下：

| 工作负载 | W8A8 draft head | W8A16 draft head |
| --- | ---: | ---: |
| 中文 | 35.75 tokens/s | 35.60 tokens/s |
| 代码 | 61.44 tokens/s | 62.87 tokens/s |
| JSON | 50.69 tokens/s | 51.23 tokens/s |

代码/JSON 文本和接受率保持不变。尽管合成 logit 误差更低，中文文本再次变化，接受率从
42.69% 降至 38.42%。每种 workload 在三次计量运行中都保持稳定。长 retrieval 和
基本生成 smoke check 均通过，但并未实现预期的中文接受率提升。仅凭代码/JSON 的微小
计时差异，不能证明这是一项普遍更好的 serving 选择；W8A8 仍是选定的基线。

恢复 W8A8，并使用默认关闭的 timing hook 和 persistent cache 后，中文/代码/JSON
分别达到 35.91 / 61.66 / 50.51 tokens/s。全部九个计量文本和接受率都复现了之前的
W8A8 运行；retrieval 与生成 smoke check 也通过。实验服务最终保持在这项恢复后的
配置上，并禁用计时。

## 有界 PLE 主机计时

在不增加 CUDA 同步的情况下，围绕现有 connector 和 CPU worker 阶段加入了默认关闭的
主机 timer。完成 W8A16 sweep 和禁用计时的 warmup 后，代码请求和中文请求各自捕获了
32 次 PLE transaction。connector/worker sequence number 完全匹配。每个窗口包含
两次 context transaction 和 30 次四 token transaction；表中仅报告后者的中位数：

| 主机时间 | 代码 | 中文 |
| --- | ---: | ---: |
| Connector 总阻塞时间 | 1.576 ms | 1.538 ms |
| Connector 等待 worker 完成 | 1.385 ms | 1.353 ms |
| Worker 总时间 | 1.212 ms | 1.183 ms |
| Worker lookup/反量化 | 0.836 ms | 0.842 ms |

Worker 时间嵌套在 connector 等待时间内，不得再次相加。输出 copy enqueue 和已有的
最终 stream 同步也是主机计时，并非直接 DMA 时长。Context 输入 staging 包含等待
先前 GPU 依赖的时间；不得将其标为 CPU lookup 时间。

对于这些完成 warmup 的单请求 workload，每次四 token transaction 中，PLE 会阻塞
主机约 1.5–1.6 ms。它无法解释先前 GPU trace 中的全部间隙，并且其开销远小于 target
Graph 或完整词表 projection。没有测量冷页和并发请求行为。sampling 范围受到限制，
随后被禁用；主动采集前先进行了普通计时运行。

实验 launcher 现在会在容器原始路径中持久化 Triton cache。W8A16 启动的
profile/cache/warmup 阶段耗时 96.91 s，而前一次 W8A8 启动为 151.78 s。head 实现
也发生了变化，因此这只是一次观测到的启动差异，不是隔离出的 cache 加速测量。
随后恢复 W8A8 的启动在同一阶段耗时 68.79 s。

## W8A8 target 性能分析与 MXFP8 tactic 对比

2026-09-13 的后续测试保留了原生 GDN、确定性 QSA、K3、CPU-offloaded PLE 和完整
词表 W8A8 draft head。只增加了按需 Torch profiling；没有复用较早的 BF16-draft
profiling launcher。关闭 sampling 后，相同的三次运行流程测得中文/代码/JSON 分别为
35.912 / 61.581 / 50.436 tokens/s。全部九个计量文本、token 数和 speculative-decoding
计数器增量均与恢复后的 W8A8 基线一致。这些计时不能证明又一次性能提升。

每条中文/代码 trace 都包含一次 context iteration、九次 decode iteration 和 38 次
Graph launch。通过 launch correlation 和原生 GDN kernel 识别 target graph，而不是
假定 graph ID 可以跨运行沿用。观测到的序列是先执行两次初始 draft launch，随后是九组
`[target, draft-prefill, draft, draft]`。只有八个完整的连续 target 开始间隔可用：

| 观测组件，中位数 | 中文 | 代码 |
| --- | ---: | ---: |
| Target Graph GPU 时间跨度 | 42.806 ms | 41.806 ms |
| 三个 draft Graph 时间跨度之和 | 11.117 ms | 11.079 ms |
| Target 开始至最终 draft 完成 | 58.785 ms | 57.808 ms |
| 连续 target 开始间隔 | 67.328 ms | 64.700 ms |

Target kernel 的名称/grid 计数与较早的 BF16-draft trace 完全一致。三个 draft 时间
跨度减少约 6.6 ms，与替换其中三次词表 projection 相符。forward 之间的间隙也发生了
变化；不要将整个周期差异归因于 head，也不要把这些带 instrumentation 的短 trace
直接换算成服务吞吐量。BF16 target head 仍位于 target Graph 之外。

根据 Graph-launch correlation 过滤 target kernel，得到以下**每次 verification step
的 kernel 时间总和均值**，而不是互斥 wall time：

| Target kernel 系列 | 中文 | 代码 |
| --- | ---: | ---: |
| NVFP4 分组 MoE GEMM | 14.453 ms | 14.015 ms |
| MXFP8 稠密 GEMM | 13.156 ms | 13.151 ms |
| BF16 稠密 GEMM，layer 映射不完整 | 7.686 ms | 7.667 ms |
| MXFP8 激活量化 | 1.317 ms | 1.325 ms |
| 原生 GDN | 1.098 ms | 1.097 ms |

此表省略了其他 routing、attention 和 metadata kernel。多个 stream 会重叠，因此将
这些行相加不能得到 target latency。这使后续调查方向转向 target projection 和 MoE，
而不是再次移植 GDN 或使用 GPU-resident PLE。

### 真实权重 input-projection tactic 探测

开销最大的重复 MXFP8 kernel 在每个 target step 中出现 36 次，位于激活量化之后、
GDN 卷积之前。检查点 header 确认 layer 0 分别具有 QKV `[10240,2560]` 和
Z `[6144,2560]` E4M3 权重，U8 E8M0 scale 的形状为 `[N,80]`。它们合并后的
projection 为 `[16384,2560]`，包括 scale 在内约 41.25 MiB。一项独立探测仅加载这些
真实权重，并使用带固定 seed 的合成 BF16 激活。

在固定版本的 FlashInfer 运行时中，CUTLASS runner 通过 `get_valid_tactics` 暴露
32 种 tactic；显式选择时仍保留权重和激活量化格式。`M=1` 和 `M=4` 均测试了全部
32 种 tactic，另加原始默认值 `tactic=-1`，它映射到 tactic 0。计时使用 CUDA Graph
replay，在 warmup 后进行五批、每批 100 次 replay，并排除一次性权重加载。另一份
profile 将每种成功的 M4 tactic 映射到对应 kernel 名称/grid：

| M4 projection，包含激活量化 | 时间 |
| --- | ---: |
| 原始库默认值 | 0.209866 ms |
| Tactic 8，与服务 trace 匹配 | 0.170678 ms |
| Tactic 3，本次探测中最快 | 0.170052 ms |

包含以下内容的服务 kernel signature
`DeviceGemmMxfp8GemmSm100___nv_bfloat16_128_64_128_2_2_1_2SM`, grid
为 `[2,256,1]`；按完整 kernel 名称和 grid 比较时，它唯一匹配 tactic 8。这也印证了
该 projection 的 layer/shape 映射。服务 autotuning 已经选择了明显优于原始库默认值的
配置。**不要把相对于该默认值的差异报告为服务加速。** Tactic ID 仅适用于此运行时。

全部 66 个 tactic/shape 对比均成功，对于受测输入，它们与原始默认结果 bitwise 相等。
Tactic 3 还通过了八次输入变化的 Graph 对比：每个 M 分别使用零输入和三个 seed，
并复用同一个 captured graph。真实权重加合成激活不能证明通用模型质量等价。观测到的
设备空闲内存增量始终低于 403 MiB；操作间的采样不能证明严格的瞬时峰值。

Tactic 3 与匹配服务的 tactic 之间仅相差 0.37%，即 36 次调用总计约 0.023 ms。
这一次运行的差异可能只是计时波动，不足以支持变更服务。保留现有 tactic 选择；下一步
应调查其他 projection 形状或 MoE 路径。

2823-token retrieval 回归测试通过 3/3。恢复普通 W8A8 launcher 后，又在独立 GPU
探测结束后重复进行了生成 smoke check：三个文本均与之前的基线一致，全部正常停止，
JSON 正确。健康检查保持为 200，内存 watchdog 持续启用。没有提升任何新的 serving
变体；原始 trace 和探测 artifact 仍保存在 Git 之外。

## 服务状态

FP8 KV 仍是一项独立的容量/质量实验。当前 4096-token 单请求测试不需要它；上游方案
本身报告了 FP8 KV 的长推理质量回归，因此在隔离 speculative-decoding 性能时保留
BF16。初始 API 是仅绑定 loopback 的实验容器，并非持久化的机群推理服务。

探测脚本和详细结果保存在公开仓库之外。

## 外部对比

Flash Next 仓库报告 Spark 上单流约为 48.7 tokens/s，八流聚合为 162.9 tokens/s。
Lazycat 厂商技术负责人的博客给出了其自身硬件、模型和 workload 条件下的厂商适配结果。
有关较新的 Thor 宣称数据，请参阅[厂商产品页快照](../../README.md#厂商公布的性能快照)；
两者都不是与本地 workload 的受控对比。

## 参考资料

- [所审查修订版的 Qwen3.8 Flash Next Spark 部署](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark/tree/d03809008834124e80223c3482f2ddb59577a48f)
- [Lazycat 技术负责人的模型适配报告](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — 外部结果，并非本地测量。

## SG2026-10-04：自有 SGLang S0 基础验收

本节记录 2026-10-04 已完成的自有 NixOS/SGLang 实验，与上文 vLLM 实验分开。
S0 是 C1 单请求、target-only、无 MTP、禁用 CUDA Graph 的短输入基线，已正常 ready
并通过定向功能验收；不是全 BF16 dense-side 的 F0，也不使用 Lazycat 运行时。
每项实验完成后将结果写回本页；G1 在本节初始记录中仅为待测配置，后续结果见
[C1 Graph 配对实测](#sg2026-10-04-c1-graph-配对实测)。

### 来源与权重保全

公开 ARM64 SGLang `v0.5.20`，engine 固定为
`94602c9c2b7cbdb8efd5c52802dac6a1c180089e`，镜像固定为
`lmsysorg/sglang@sha256:b0d8718a4424bb22e448e04407ab3ce5f7399a4c5fc702d6fbe36c3772ec8862`。
target 为 `RadixArk/Qwen3.8-Flash-Next-NVFP4` 修订版
`7b719225242aacd3dbd3f9407468c2ee9a9d2594`；metadata/conversions 来自
`manateelazycat/Qwen3.8-Flash-Next-SGLang-Thor` 修订版
`b8c4002b44544436bfc16b1ff7fe6ebb3ced07a6`。复用其检查点配置不等于使用厂商运行时。

实际检查点为 `modelopt_mixed`，包含 FP8 side；完整词表 head 为 FP8
`[248320,2560]`，block scale 为 FP32 `[1940,20]`。CLI `--dtype bfloat16`
不会恢复已经量化的权重，不能据此称为 BF16 head 或全 BF16 dense 基线。
从原应用缓存复制的 235 个文件共 133,414,193,791 bytes，已核对源 SHA-256 并回读副本。
原系统盘以只读、`norecovery` 挂载，完成后卸载；源保持不变，没有重新下载。

实现入口为 [flash-next.nix](../../../../../hosts/personal/fixed/thor/flash-next.nix)，
参数见 [baseline.json](../../../../../hosts/personal/fixed/thor/flash-next/baseline.json)。
同目录的 [run.sh](../../../../../hosts/personal/fixed/thor/flash-next/run.sh)、
[prepare.sh](../../../../../hosts/personal/fixed/thor/flash-next/prepare.sh) 和
[memwatch.sh](../../../../../hosts/personal/fixed/thor/flash-next/memwatch.sh)
负责启动、源码 overlay 和内存 guard；补丁来源及前后 SHA-256 见
[manifest.json](../../../../../hosts/personal/fixed/thor/flash-next/manifest.json)。
定向探测见 [head-probe.py](../../../../../hosts/personal/fixed/thor/flash-next/head-probe.py)、
[head-gemm-probe.py](../../../../../hosts/personal/fixed/thor/flash-next/head-gemm-probe.py) 和
[probe.py](../../../../../hosts/personal/fixed/thor/flash-next/probe.py)。

### S0 配置与生命周期

| 项目 | 已验收的 S0 设置或观测 |
| --- | --- |
| 执行模式 | C1，最多一个请求，target-only；MTP、decode/prefill Graph 均禁用 |
| 容量边界 | token pool 8192；原生 context 配置 262144，不代表 262K 可用容量或长上下文已验证 |
| Cache | BF16 KV、FP32 SSM；SSM cache 8，page size 64 |
| Prefill / 内存 | chunk 512，prefill/decode interval 1，static fraction 0.8 |
| PLE | file offload，文件 RSS budget 4 GB |
| 算子 | FA4 `4.0.0b31`；GDN Triton；MoE/FP4 FlashInfer CUTLASS；FP8 Triton |
| 隔离与保护 | host 仅发布 loopback `8890`；容器限额 `108g`，主机 memory guard + StopLock；1 小时自动停，无自动重启 |
| 清理 | 仅清理本实验持有 CID 的容器，不清理其他容器 |
| 启动观测 | 本 epoch 18:11 启动、18:18 ready，约 7 分钟；仅单次观察，不是时限保证 |
| 内存观测 | running 时 `MemAvailable` 采样约 36 GiB，不是峰值测量 |

仅在 sandbox builder 构建两项 systemd unit 与运行闭包，完成 copy、runtime link 和
health 检查，没有完整 system activation。运行时一小时自动停止且不自动恢复原 27B
服务；用户已允许该服务继续停用。不声称完整系统部署或 cold reboot 已通过。

### 两项兼容性修复

FA4 b31 与 overlay TVM FFI `0.1.14` 曾使 TileLang `0.1.12` 因 `__ffi_repr__`
重复注册而 SIGABRT。改为仅 overlay FA4，保留镜像 FFI `0.1.11`；b31 声明
`>=0.1.12` 的元数据例外依据是 [FA4 PR #2948](https://github.com/Dao-AILab/flash-attention/pull/2948)
已放宽至 `0.1.11`。native imports 及 SM110 上 FA4 dense/varlen 探测通过：
Q=257、K=1025、query heads=24、KV heads=2、head dimension=256，对独立 FP32
参考的最大绝对误差为 0.0011687875。这不推广为所有 GPU 或所有 FA4 版本均兼容。

原 vocab loader 把 block scale 的 1940 行误当成 248320 个词表行，导致 assertion。
补丁严格限于 TP1、non-presharded、无 added vocabulary 的 `BlockQuantScaleParameter`
分支，只修正 scale 加载坐标，保留数值，不改变数学计算；源码 hash 由 manifest 固定。
CPU 13 项检查通过，覆盖精确 `[1940,20]` markers、完整真实 scale 和 FP8 bit sample；
raw head payload 在修复前后不变。

小规模真实 Triton W8A8 kernel 对照独立 FP64 参考，通过 FP32 accumulation 与 BF16
rounding 误差界检查；activation quantization 另行 bitwise 匹配：

| `(M,N,K)` | W8A8 最大绝对误差 | W8A8 对 BF16 激活 weight-only 的 RMSE |
| --- | ---: | ---: |
| `(1,256,128)` | 0.008739 | 0.046205 |
| `(17,257,256)` | 0.062279 | 0.128116 |
| `(3,385,256)` | 0.061995 | 0.177644 |

因此 `FP8_PB_WO` 标签不保证 stock SGLang 计算与 weight-only 数值等价。这些检查不是
完整 head 或完整模型 parity，也不是长生成质量证明。

### 功能与有限计时

| Case | 重复次数 | 结果与边界 |
| --- | --- | --- |
| `exact-short-output` | 1 warm + 3 measured | 4/4 pass，精确输出 `372` |
| `strict-json-schema` | 1 warm + 3 measured | 4/4 pass，`answer=42`、`label=thor` |
| `tool-get-weather` | 1 warm + 3 measured | 4/4 pass，恰好调用 `get_weather(city=Beijing)` |
| `historical-water-cycle-128` | 1 warm + 1 measured | 中文生成正常，但被 token budget 截断；`check=not_checked`，不计为完整质量 pass |

前三项共 12 次全部通过，未观察到 reasoning 文本。中文 case 的单次 measured 首内容
延迟为 0.32513 s、wall time 为 12.93975 s、content decode estimate 为
10.06768 tokens/s；记录带 isolation label。这只是短时单次观察，不是严格跨模型 A/B、
正式宽负载基准或速度上限。

已完成的静态测试共 98 项（14 unit + 72 benchmark + 12 patch）通过；两项 Nix unit
及运行闭包的 sandbox builder build/copy/link/health 检查通过。上述 CPU/GPU 探测
计数各自独立，不与静态测试计数混合。raw/evidence 保存在远端
`/var/lib/thor-flash-next/observations/initial-S0/`，不复制原始响应、模型文件、私有地址
或凭据到公开仓。

### G1 待测边界（初始记录）

以下保留初始验收时的待测条款；后续已完成的 Graph 测量见
[C1 Graph 配对实测](#sg2026-10-04-c1-graph-配对实测)，不替换历史证据。

G1 为单变量 C1 decodeGraph 对照，由 `services.thorFlashNext.decodeGraph = true`
从 S0 参数生成：仅启用 full decode Graph 并限制最大 batch size 为 1；prefill Graph
仍禁用，其他 pins/非 Graph 设置不变且无 MTP。配置定义见上述模块；本节不声称已通过
capture/replay、正确性或吞吐量测量，结果待主 agent 实测后追加。

自有 SGLang 运行时尚无正式宽负载、长上下文、cancel/stress、MTP 或 Graph 测量。
上文 vLLM 的 Graph/MTP 结果不能移作本运行时的验收证据。

## SG2026-10-04 C1 Graph 配对实测

本轮在上述 S0 基础验收后完成 C1、无 MTP 的 S0/G1 配对测量。G1 是所测短输入、
固定输出长度场景的强候选，中文/代码 decode estimate 分别约为 S0 的 **2.97/3.04 倍**；
不是生产 ready 判定，也不能与上文 vLLM 数字直接作受控比较。

### 配置与协议

| 项目 | 本轮控制与边界 |
| --- | --- |
| S0 / G1 | S0 禁用 Graph；G1 full decode Graph、最大 batch size 1；两者 prefill Graph 禁用、无 MTP |
| G1 来源 | 上述 `flash-next.nix` 的 `services.thorFlashNext.decodeGraph = true` 生成配置，不另写实验参数集 |
| 相同设置 | SGLang `v0.5.20`、engine `94602c9c2b7cbdb8efd5c52802dac6a1c180089e`、同一 `b0d8718a…` 镜像；实际 mixed FP8 payload、FP32 SSM、BF16 KV、token pool 8192/C1；其余 pins/flags 均同 S0 |
| Throughput case | 沿用历史水循环中文 128-token、interval 合并代码 256-token 的原 prompt；每配置、每 case 为 1 warm + 3 measured |
| 请求控制 | `temperature=0`、`seed=42`、`enable_thinking=false`；吞吐请求 `ignore_eos=true` 固定输出长度，质量 smoke 不忽略 EOS |
| Prefix 协议 | shared-prefix，固定原 prompt，无 isolation nonce；不主动 flush 共享服务，允许 prefix reuse，但不强制 cold，也不保证命中 |
| 执行顺序 | 先全部 S0，后 G1，仅一次配置切换；不是交叉或 counterbalanced 实验 |

中文/代码各自的所有 wire request hash 在两配置间核对一致。实际日志中部分请求的
cached token 为 0，因此不宣称实际 90% cache hits，也不把 TTFC 当成冷 prefill 延迟。
配置为单变量，但生成轨迹并未固定；这不是固定 generated-token 的 kernel benchmark。

### 配对计时与输出

下表为每 case 三次 measured 的中位数，不包含 warmup；decode estimate 沿用本页
`(completion_tokens - 1) / (stream_end - first_content)` 的定义，TTFC 为首内容延迟。

| Case | 配置 | Decode estimate（tokens/s） | TTFC（s） | Wall（s） | G1/S0 decode |
| --- | --- | ---: | ---: | ---: | ---: |
| 中文 128 | S0 | 10.010 | 0.301 | 12.978 | n/a |
| 中文 128 | G1 | 29.778 | 0.199 | 4.462 | 2.975x |
| 代码 256 | S0 | 10.022 | 0.298 | 25.741 | n/a |
| 代码 256 | G1 | 30.466 | 0.199 | 8.568 | 3.040x |

每 case 的三次 measured completion 长度在 S0/G1 下均为指定的 128/256 token。
三次 measured 的不同 response hash 数：中文 S0/G1 为 3/3，代码为 3/1。
`temperature=0` 和 `seed=42` 不保证 bitwise 确定性；本轮不认定轨迹差异的单一原因，
也不将固定长度中文/代码计时当作完整生成质量 pass。

### 功能与 Graph 证据

| 检查 | 本轮结果 |
| --- | --- |
| 自动质量 smoke | 每配置的 exact output、strict schema、tool 三项各 1 warm + 3 measured；S0、G1 分别 12/12 通过 |
| G1 capture/replay | 捕获成功，多个实际请求的 replay 日志记录 `decode cuda_graph=True` |
| Capture 开销 | elapsed 1.29 s，报告额外 0.01 GB；当时 GPU available 38.44 GB |
| Prefill | 日志 `graph=False`，与两配置的 prefill Graph 禁用一致 |
| Nix/运行验证 | 本轮默认 false 与 `extendModules` true 两配置的两项 unit/pinned closure 构建，以及实际 capture/replay 通过；不是 full-system activation 或 cold boot 验证 |

本轮复跑 99 项静态测试（14 unit + 73 benchmark + 12 patch）通过。ignore-EOS
fixture 仅给这两个固定长度吞吐 case 增加 flag，不改变质量请求或 CLI 默认值。

### 资源与启动观测

| Throughput 采样 | 样本数 | 最低 MemAvailable（GiB） | 最高温度（°C） | 最高 GPU reported power（W） |
| --- | ---: | ---: | ---: | ---: |
| S0 | 151 | 36.4852 | 47 | 25.34 |
| G1 | 51 | 36.3872 | 51 | 39.95 |

这些 min/max 是离散采样，不是精确瞬时 peak。`smi` 时钟为 NA，不能证明同频运行，
也不能将性能变化归因于 thermal；功耗是 GPU reported rail，不是整机功耗。

| 启动 epoch | Start → ready | 观测 |
| --- | --- | --- |
| 本轮 S0 | 20:01 → 20:19，约 18 分钟 | 重新加载模型及写入 PLE |
| 本轮 G1 | 20:37 → 20:55，约 18 分钟 | engine `load_weight=1008.35 s`、`scheduler=1025.58 s`、`tokenizer=1034.2 s` |

本轮启动主要耗时为重新加载/写入 47.7 GiB PLE，在 4 GiB RSS cap 下，每个 5.2 GB
分片约 82 s。Graph capture 仅 1.29 s，不能把整体加载延迟归因于 Graph；这些 startup
字段也不应相加为 wall time。初始 S0 的 18:11 → 18:18、约 7 分钟仍是保留的单次
观测，不是后续启动时限保证。

### 状态与后续边界

- 用户保持原 27B 服务关闭；没有 production route 切换或 full-system activation。
  G1 继续作为临时 loopback `8890` 服务，保持 1 小时限时、无自动重启，不自动复活 27B。
- 默认 module option 仍为 `false`；本轮不在未经 review 的情况下修改默认值。
  后续先验证 G1 稳定性与实际 thinking，再评估 MTP。
- 本轮没有长上下文、并发、长输出、实际 reasoning、MTP 或普遍稳定性的验收证据。
  自动 smoke 与短时吞吐结果不推广为通用质量或生产可用性。
- raw/evidence 保留在私有目录
  `/var/lib/thor-flash-next/observations/decode-graph-20261004/{S0,G1}/`；不贴原始模型回复、
  host IP、user ID 或其他私有运行数据。
- 初始源码准备已由 `89df3e5` 在独立分支 `feat/thor-flash-next-owned` 提交并推送；
  本轮文档及 ignore-EOS fixture 作为后续独立提交，每轮实验结果写回本页。

## SG2026-10-05 G1 thinking / continuous 有限实验

本轮继承 [G1 配对实测](#sg2026-10-04-c1-graph-配对实测) 的运行配置，验证实际
thinking 控制与有限连续生成。三道合成题各两次重复中，off/low/medium 分别通过
0/6、5/6、4/6；连续账本通过，重复序列从第一行即违反格式。以下是任务级观测，
不是通用 benchmark accuracy、长期数值稳定性或生产 ready 判定。

### 继承配置与行政窗口

| 项目 | 本轮控制与边界 |
| --- | --- |
| 不变的 G1 | 公开 SGLang `v0.5.20`、同一 `94602c9c…` engine / `b0d8718a…` 镜像；完整 pins 见 S0 来源节，不另换任何 inference flag |
| 实际权重与执行 | 同一 mixed FP8 payload / block-scaled FP8 完整词表 head、TP1 scale-loader 补丁；FP32 SSM、BF16 KV、pool 8192、C1 full decode Graph BS1，prefill Graph 禁用、无 MTP |
| 行政时限 | 新增 `services.thorFlashNext.runtimeMaxSec`，类型为正整数、默认 3600；仅本轮 override 为 5400 秒（90 分钟） |
| 应用方式 | 编译 unit 后 runtime link，不 restart；实验过程中 InvocationID 保持不变，host guard / CID cleanup 不变；不是 full-system activation |
| 单个启动 epoch | CST 2026-10-05 00:11 启动、约 00:30 ready，约 18 分钟；仅一次启动观测 |
| 作业时间 | CST 约 00:50 至 01:13；完成时间为 UTC `2026-10-04T17:13:02Z`，即 CST 2026-10-05 01:13:02 |
| 生命周期 | 90 分钟从 00:11 启动计时，自动停止边界约 01:41；无自动重启，不代表无限运行或持久服务 |
| 路由 | 原 27B 服务保持停止，没有 production route 切换，也不自动恢复 27B |

延长时限只为容纳本轮已规划请求，是行政窗口，不是新的 inference variable。
上述时间不构成启动或完成时限保证。作业完成后另于 CST 01:43 核验：服务已按
90 分钟上限结束，`Result=timeout` 是预定时限触发，日志显示正常 shutdown；容器、
CID marker 与 guard 均已回收，没有 memory-stop 锁，`MemAvailable` 恢复约 119 GiB。
原 27B 及健康检查仍停止；这不是任务期间的传输或模型故障。

### 公开资产与检查口径

新增 [thinking-stability.json](../../benchmark/thinking-stability.json) 共 13 个 case：
三道题各 off/low/medium 九项、两个 continuous ledger 和两个 continuous sequence。
[thinking-probe.py](../../../../../hosts/personal/fixed/thor/flash-next/thinking-probe.py)
只加载本地 tokenizer/Jinja；[test-thor-thinking.py](../../../../../utils/test-thor-thinking.py)
独立核对 oracle、配对输入和严格 checker。它们是新合成实验资产，不是历史结果。

本轮 [benchmark client](../../../../../utils/benchmark-thor.py) 兼容 SGLang 的根级
`usage.reasoning_tokens`，仅接受严格非负整数，不接受 bool、浮点或字符串。根级与
`completion_tokens_details.reasoning_tokens` 冲突时，reasoning / non-reasoning 拆分
均为 null，`reasoning_tokens_source=conflict`；缺少有效 completion 总数时也不强行拆分。
即便没有 completion 总数，根级正 reasoning count 仍使 thinking-off 检查失败。
不以 SSE chunk 数或事件间隔估算 token 数，本轮采用 API 报告的根级 reasoning count。

| 检查 | 规则或已完成验证 |
| --- | --- |
| Thinking JSON | 严格字段、整数类型与正确值；必须自然 `stop`，错误答案或 `length` 均失败 |
| Continuous ledger | 必须自然 `stop`、完整行数；逐行严格核对 `seq`、transaction ID、整数类型、顺序与累计 balance，不执行生成代码 |
| Continuous sequence | 精确行格式、编号、词序及句点；`length` 时只允许完整合法前缀及下一行合法 partial，记录 `full_task_completed=false`；提前自然停止不足 500 行则失败 |
| 静态测试 | 已完成 130 项全部通过：82 benchmark + 21 thinking + 15 unit + 12 patch；不与 API 请求或 CPU render 次数相加 |
| 空选择防护 | 新 fixture 没有默认 `smoke` case；省略匹配 suite/case 时在 preflight 失败，避免零请求被记录成 successful run |

### Thinking 控制证据

实际本地 `chat_template.jinja` SHA-256 为
`c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`。
该文件不是拿 SGLang-Thor metadata/conversions 路径中的模板代替 target 模板；其来源为
前述固定 `RadixArk` target 修订版 `7b719225…`。HF token rendering 显式使用
`return_dict=False` 并检查 flat integer token IDs。

| 控制层 | 本轮证据与限制 |
| --- | --- |
| 本地 Jinja | low、medium、xhigh rendering 三者不同；省略 effort 默认 xhigh；`high` 抛出 `TemplateError` |
| Thinking 开关 | off 渲染关闭的 think block；low/medium 渲染打开的 think block |
| 同题配对 | off/low/medium 原始 messages 相同，仅 `chat_template_kwargs` 不同；不是三个不同题面 |
| CPU render | 13 个 case 的输入为 62 至 852 token，最大 852 |
| 实际 API | 26 个 task trial 的 `usage.prompt_tokens` 全部与各自本地 render 长度吻合；实际观察到 reasoning flow 和报告 count |
| 后端支持 | 固定 engine 的源码 forwarding，加上 render、API 长度及实际 reasoning 证据，支持软提示已生效；仅长度一致不证明后端 prompt bytes 逐字相同 |

`effort_kwarg=None` 不能证明 low 不受支持。low 是要求 brief thinking 的软提示，不保证
短或正确；medium 没有额外 instruction，不是硬预算。本轮没有 `thinking_budget`。
Thinking-on 流中实际观察到首 reasoning 与首 content 的分离，分别记录
`first_reasoning_seconds` / `first_content_seconds`，不能把首 reasoning 当成首正文。

### 请求协议与恢复检查

| 项目 | 本轮协议 |
| --- | --- |
| 请求控制 | `temperature=0`、`seed=42`；shared-prefix、无 isolation nonce，不主动 flush，也不保证 cold 或 cache 命中 |
| 输出预算 | thinking、ledger 与长 sequence 均为 4096；辅助短 sequence 为 1536；预算是上限，不强制输出长度 |
| 容量 | 预检限制 `P <= 2048`、`O <= 4096`，在 pool 8192 内留有余量；未测试真正 8K/16K 输出 |
| 停止条件 | 不使用 `ignore_eos`，无 grammar 保送；ledger/思考题要求自然结束，sequence 允许受预算截断的合法前缀 |
| 顺序与重复 | 13 个 case 两轮 round-robin；每个 trial 独立执行 `--repeats 1`，共 26 个 task trial |
| 任务失败 | wrong final / length failure 确实返回 1 并记录；随后按预定计划执行下一独立 trial，不绕过或修改 failed status |
| 中止条件 | 任何 transport、model、control failure 或短 recovery 失败均中止整个作业 |
| Recovery | 1 次初始 warm + 每个 task trial 后 1 次精确 `372` 检查，共 27/27 pass；transport failure 为 0，服务保持同一 InvocationID |

### 思考任务结果

Oracle 在公开测试中独立核对：digit 穷举得到唯一答案 294；two workers 的总工时
24 给出双 worker 下界 12，测试含满足依赖和不重叠约束的 makespan 12 witness；
signed ledger 32 从初始 37 逐笔计算，期望 final 4、minimum -68、negative steps 18。
下表每行均为两次 trial；token 对按轮次排列，total 指 API completion 总数
（包含 reasoning），不是仅正文。

| 任务 | 档位 | 严格通过 | Reasoning tokens（两次） | Total tokens（两次） | Wall 中位数（s） |
| --- | --- | ---: | --- | --- | ---: |
| Digit | off | 0/2 | 0 / 0 | 9 / 9 | 1.368 |
| Digit | low | 2/2 | 571 / 537 | 581 / 547 | 19.326 |
| Digit | medium | 2/2 | 609 / 586 | 619 / 596 | 20.403 |
| Two workers | off | 0/2 | 0 / 0 | 9 / 9 | 0.576 |
| Two workers | low | 1/2 | 4096 / 3896 | 4096 / 3906 | 137.451 |
| Two workers | medium | 0/2 | 4072 / 4096 | 4082 / 4096 | 140.450 |
| Signed ledger 32 | off | 0/2 | 0 / 0 | 32 / 32 | 1.397 |
| Signed ledger 32 | low | 2/2 | 1021 / 1108 | 1041 / 1128 | 36.801 |
| Signed ledger 32 | medium | 2/2 | 1336 / 1248 | 1356 / 1268 | 44.267 |

Two workers 的 low 第一次耗尽 4096-token 预算，`length` 且无 final；第二次自然
`stop` 并给出最优值 12。medium 第一次自然 `stop` 但答案非最优，第二次 `length`
且无 final。off 的三题均给出错误值。wall 中位数包含这些错误/截断 trial，不是成功
请求平均耗时；low 也能把全部预算用于 reasoning 而没有正文。

汇总 off 0/6、low 5/6、medium 4/6 只覆盖三道合成题、每档两次重复，不能推广成模型
benchmark accuracy 或 low 普遍优于 medium。此前约 30 tokens/s 的短 decode 观测
也不意味着 thinking 节省 wall time。

### 连续生成与严格失败

以下四个 case 都关闭 thinking，各重复两次。checksum 是逐行 balance 之和，
不是 final balance；每个账本行都与独立 oracle 核对。

| Case | 严格检查通过 | 输出 token（两次） | Wall 中位数（s） | 停止与核对结果 |
| --- | ---: | --- | ---: | --- |
| Ledger 8 | 2/2 | 142 / 142 | 5.026 | 自然 `stop`，完整 8 行，balance checksum 78 |
| Ledger 96 | 2/2 | 1799 / 1799 | 62.255 | 自然 `stop`，完整 96 行，balance checksum -910 |
| Sequence 1536 | 0/2 | 1536 / 1536 | 51.825 | 两次 `length`，第一行即缺少要求的终止句点 |
| Sequence 4096 | 0/2 | 4096 / 4096 | 139.024 | 两次 `length`，同样从第一行违反格式 |

账本在自然 EOS 前完成，未强制 length；最长成功账本仅输出 1799 token，因此不证明
正确账本覆盖了 4096-token 压力边界。sequence 的失败从第一行就发生，是格式不遵守，
不能据此当作长程漂移证据，strict gate 不放宽。

只作事后辅助诊断，忽略这一已知 missing-dot 差异后，1536 两次均有 137 条编号/词序
完整的行；4096 两次均有 350 条及合法 partial 351。该有限合成样本未发现额外跳号或
循环，但这不是原 strict checker pass，不改变四个 trial 的 failed status，也不声称
500 行任务全部完成。

### 资源、证据与后续

| 本轮资源采样 | 观测值 |
| --- | ---: |
| 最低 MemAvailable | 37.3106 GiB |
| 最高温度 | 60 °C |
| 最高 GPU reported power | 41.15 W |
| 时钟 | NA |

这些 min/max 来自离散采样，不是瞬时真实 peak；功耗不代表整机功耗，NA 时钟也不支持
同频假设。memory guard 未触发，全部短 recovery 通过，但不足以证明通用质量、长时
运行或长期数值稳定性。任务失败本身不能证明 precision/SSM 漂移；要归因数值漂移，
需要 teacher-forced、logit/reference 对照，而不是以错误答案或格式失败替代。

下一轮先扩大 thinking 任务、测试较长的自然 prose，并补充 cancel / 混合负载检查。
MTP 仍未启用，本轮不存在 speculative 接受率；不据此晋升生产配置。
raw/evidence 保留在私有
`/var/lib/thor-flash-next/observations/thinking-stability-20261005/`，不公开 raw chain、
原始回复、host IP 或运行 UUID。遵循每轮 record + push 的要求，本轮代码和本页记录
由主 agent 负责后续新 revision 的提交/推送；此处不预填尚未产生的 commit ID。

## 生成安全验收：自然长文本与客户端取消

2026-10-05，在图 `G1`（target-only，C1 full decode graph，max batch 1，BF16 KV、
FP32 SSM，无 MTP）上补做生成安全验收，不改变任何 inference flags；5400 秒仍只是
行政窗口。新增 `docs/inference/thor/benchmark/generation-safety.json` 与一个
`natural_prose` strict gate，并由 `record-flash-next-runtime.py` 的 `G1` 分支核验 runtime
记录；观测到的 `speculative_algorithm` 为 `disabled`，`cuda_graph_backend_decode` 为
`full`，`cuda_graph_max_bs_decode` 为 1。

**自然长文本**

提示要求约 700 字、结构完整并自然结束的中文说明文；budget 为 2048（off）和 4096
（low），temperature 0，每档重复两次。gate 要求 `finish_reason == stop`、无 tool call、
内容达到 `min_chars`。

| Case | 严格通过 | 输出字符 | completion / reasoning token | Wall（s） | 停止 |
| --- | ---: | ---: | --- | ---: | --- |
| natural-prose-off | 2/2 | 837 / 844 | 467 / 483（reasoning 0） | 16.55 / 16.58 | 自然 `stop` |
| natural-prose-low | 2/2 | 873 / 784 | 687 / 633（reasoning 172 / 176） | 23.68 / 21.53 | 自然 `stop` |

thinking low 在首次内容前先输出 reasoning，`first_content` 约 6.05–6.09 s；off 约
0.19–0.43 s。
长度检查只证明在预算内自然终止，不评估事实正确性、连贯性或文风。

**客户端取消与恢复**

对 `cancel-long-generation`（`ignore_eos`，budget 4096）流式生成约 20 秒后由客户端
主动断开连接，随后立即发送一个短 JSON 请求。

| 轮次 | 断开前 content 事件 | 耗时（s） | 断开后服务存活 | 恢复 JSON |
| --- | ---: | ---: | --- | --- |
| 1 | 602 | 20.02 | 是 | 通过 |
| 2 | 607 | 20.02 | 是 | 通过（0.44–0.48 s） |

两轮断开前都在持续产出 token，说明取消发生在生成中途。取消计数由
`utils/run-flash-next-safety.py` 从被中断的流中统计并写入 `summary.json`，未保留
原始 partial stream。此检查证明客户端中断后服务未崩溃且可继续服务，但不证明服务端
已立即停止 GPU 计算、释放 KV/state 或回收显存；本轮没有测量取消路径的服务端耗时。

**资源与边界**

| 采样 | 观测值 |
| --- | ---: |
| 最低 MemAvailable | 37.2333 GiB |
| 最高温度 | 52 °C |
| 最高 GPU reported power | 38.76 W |

四次 prose 与两次 recovery 均为 `completed`，无传输失败。样本小，只覆盖 greedy、
单请求、短上下文；不能证明通用质量、长时稳定性或并发安全。验收结束后服务正常停止，
容器与 guard 清理；停止后即时采样 MemAvailable 约 119.5–120 GiB，该值未写入证据目录。

本轮不启用 MTP，不存在 speculative 接受率。raw/evidence 保留在私有
`/var/lib/thor-flash-next/observations/safety-20261005/`，不公开原始回复或运行 UUID。
代码、fixture 与本页记录由主 agent 负责新 revision 的提交/推送，此处不预填 commit ID。

只读源码核查确认：固定镜像 `lmsysorg/sglang:v0.5.20`
（`94602c9c`）已内置 `NEXTN`（作为 `EAGLE` 别名）、`qwen4_exp` MTP draft 类以及
`--speculative-token-map`，draft 目录可按独立模型加载；`optimization/` 中的
`draft-head-32768-corpus-fp8.safetensors` 在该镜像内没有 loader，`32768` 词表优化
需要另行实现。下一轮先用该镜像尝试原生 `NEXTN`（3 步 / topk 1 / 4 draft token，
全词表）对照 `G1`，再单独评估词表优化；不改变 BF16 state、FP8 KV 或上下文长度。
