# Strata：Titan RTX / A2000 推理实验

2026-10-08 至 2026-10-09（Asia/Shanghai）实测：在 64 GiB 内存的 x86 NixOS 平台上，比较 Qwen3.8-Flash-Next 的 `IQ2_XS` 与 `IQ3_XXS`、单卡与两种双卡模式，以及 52 GiB 内存预算下的 resident 模式。随后验证 Titan 主推理、A2000 专家辅助的 128K 配置，包括长文本检索、长输出、短请求回归、持续运行和取消恢复。

这是历史实验记录，不代表当前生产部署。数值、范围、文件哈希与资源采样汇总见 [results.json](results.json)。

发布准备中的日常默认档位为 **Strata low、Thor 27B medium**。下面的硬件吞吐实验使用关闭 thinking 的请求；这些历史数字不代表新档位下的回答完成耗时。

## 结论

- **A2000 可用且内存余量充足时，优先评估 IQ3_XXS + 专家辅助这个更高精度档位**：相对 IQ2 单卡，长提示 decode 只慢约 4.3%、prefill 慢约 6.2%。加卡的价值可以是把 IQ2 升到 IQ3，而不只是让同一量化跑得更快；实际本地任务的能力增益仍需按角色验证。
- **A2000 不可用或内存更紧时，IQ2_XS + Titan 单卡仍是回退基线**：本次无额外内存上限的长提示 prefill 约 1,156 tok/s、decode 91.5 tok/s。
- **同一 IQ3 下的专家辅助有加速效果**：decode 从单卡 75.9 提升至 87.6 tok/s，prefill 基本持平；测试期间两卡总 GPU 平均功耗增加约 12 W。
- **当前自动分层不适合作为这组异构 GPU 的默认方案**：两种量化的长提示 prefill 均明显慢于单卡。该结论针对本次版本、自动放置和负载，不排除其他手动分层方案。
- **52 GiB 预算下，优先 IQ2 normal**：IQ3 resident 可运行，但较慢，且“26.1 GiB 专家常驻池”不等于总内存需求。
- **IQ3 resident 的长上下文有可运行路径**：128K 配置、52 GiB 上限、禁用 swap，约 60K 与 120K token 输入均找回中段 passkey；这不是长期稳定性或综合质量评测。
- **IQ3 helper 的 128K 路径通过本机试用门槛**：48 次 60K–126K passkey 检索全部正确，120K 输入可完整生成 4096 tokens；56 分钟交替长短请求无错误、OOM 或延迟漂移，主动和排队取消后均能恢复。128K 相对 32K 的短请求 TTFT 增加约 3.6%，约 26K 输入增加约 6.9%。这仍未替代 LiteLLM/OpenCode 产品路径验收。

## 硬件与版本

| 项目 | 实测条件 |
| --- | --- |
| 平台 | Intel NUC11BTMi7；Core i7-11700B，8 核 16 线程 |
| 内存 | 标称 64 GiB；内核 `MemTotal` 约 62.33 GiB |
| 主 GPU | Titan RTX，24 GiB；PCIe 3.0 x8；SM75 |
| 辅 GPU | RTX A2000 12 GB；驱动报告 11,514 MiB；PCIe 4.0 x4；SM86 |
| 存储 | NVMe SSD |
| 系统 | NixOS，Linux 6.18.38 |
| 驱动与构建 | NVIDIA 595.71.05；CUDA NVCC 13.0.88、CUDART 13.0.96；GCC 15.2.0 |
| Strata | 0.1.40.3，`d5ea7133741e67743c0e886bb426c0ce8d69cf6c`，源码构建覆盖 `75;86` |
| llama.cpp | `3cf03257f219afbe7334045ff7c6a06ac68c627d`，由该版 setup 固定 |

这里保留推理实验所需的硬件事实，不包含设备访问、网络或机队清单。

PCIe 代际按端点与上游共同支持的能力记录，宽度为协商值；空闲时链路可降至 2.5 GT/s。本次 IQ2 自动分层启动时，A2000 的引擎 PCIe probe 约为 5.8 GB/s。

### 模型来源

目标模型使用 [ISTA-DASLab GSQ-RCO GGUF](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF)，固定 revision 为 `ed59f92082b1e93c0e96d60a8b11aab089b52f09`。不是任意同名 GGUF 量化文件之间的比较。

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| IQ2_XS shard 1 | 39,225,954,592 | `92cee27ae5bbadcd732416a0f7a7f0acc092399dbbe8f5a5efa707c2ec0a49d7` |
| IQ3_XXS shard 1 | 47,039,860,096 | `219ea929900dfa9ef091f3aa473fdba6874b65fcb36526d7d851ac9e95856d15` |
| 两者共用的 shard 2 | 28,800,138,432 | `316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113` |

shard 2 是 PLE lookup table，两个量化目录的文件名不同、内容相同；完成校验后可以用硬链接复用。共享 MTP draft 来自 [Qwen 原始检查点](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)，固定 revision 为 `de4b8e4d43b917e7706784d8bb445c9af86a3540`。setup 通过 Safetensors HTTP Range 获取所需 MTP tensors，再生成 runtime pack，不下载整个原始检查点。

## 测量方法

基础矩阵包含六组 normal 模式：两种量化分别运行 Titan 单卡、双卡自动分层、Titan 主卡加 A2000 专家辅助。另有两组 52 GiB 预算对照。

- 单请求顺序执行；每组先预热一次，再测三次短提示和三次长提示。
- `--max-context 32768 --kv int8 --spec 4 --spec-min-p 0.5`；固定专家 profile、自动 expert cache 与自动 prefill chunk。
- API 请求使用 `temperature=0`、`reasoning_effort=none`、流式 Chat Completions；性能样本 `max_tokens=256`，两道独立质量题的上限为 512。
- 长提示最初按字符长度估算，**实际约 26.3K token，不是 4K**。请求开头加入不同 nonce，实际长度与缓存复用量以 API `usage` 和 `timings` 为准；各组中位数 `cache_n=0`。
- TTFT 是客户端收到首个非空内容或推理片段的时间。Prefill/decode 分别使用 `timings.prompt_per_second`、`predicted_per_second`；不以输出 token 数除以整次请求耗时冒充 decode。
- 各指标独立取三轮中位数。输出上限不强制模型生成到 256 token；52 GiB IQ2 组有一次长提示在 171 token 提前 EOS，实际输出长度在 JSON 中保留。
- 每秒采样两卡显存、功耗、温度，主机内存及 engine RSS/HWM；后续组增加缺页、内存拆分、cgroup 与整盘 I/O。未提供的字段记为 `null`。
- 模型加载阶段和 benchmark 阶段分别统计。每组结束后确认本次服务及 engine 退出，显存连续三次回到启动前基线附近，才进入下一组。

没有统一清空 OS 文件缓存。52 GiB 通过 cgroup 限制服务进程树；客户端、提示生成和采样进程在 scope 外。这不是 Windows VM 并发、GPU 直通或真实游戏负载实验。

## 六组 normal 模式结果

长提示的三轮中位数，context 配置为 32K；本表没有施加额外 cgroup 内存上限。

| 量化 | GPU 模式 | TTFT（s） | Prefill（tok/s） | Decode（tok/s） | Engine RSS 峰值（GiB） |
| --- | --- | ---: | ---: | ---: | ---: |
| IQ2_XS | Titan 单卡 | 22.97 | 1,155.8 | 91.5 | 35.23 |
| IQ2_XS | 双卡自动分层 | 72.71 | 363.2 | 77.9 | 36.18 |
| IQ2_XS | A2000 专家辅助 | 23.44 | 1,133.7 | 89.6 | 36.16 |
| IQ3_XXS | Titan 单卡 | 24.50 | 1,084.9 | 75.9 | 42.11 |
| IQ3_XXS | 双卡自动分层 | 139.91 | 188.5 | 72.5 | 43.03 |
| IQ3_XXS | A2000 专家辅助 | 24.49 | 1,084.0 | 87.6 | 43.10 |

IQ2 的专家辅助模式没有显示吞吐收益；IQ3 长提示 decode 相对单卡提升约 15.4%。这是小规模单路测量，不是所有提示词或并发负载的通用排名。

专家辅助模式下，A2000 显存采样峰值约 10,791 MiB。两卡同步功耗读数逐时点相加后取平均：IQ2 helper 为 278.64 W、对应单卡组为 261.05 W；IQ3 helper 为 268.69 W、对应单卡组为 256.54 W。单卡组也包含闲置 A2000 的功耗；这些不是整机墙上功耗，也没有把两卡各自峰值相加冒充同步峰值。

### 换一个比较轴：加卡换取更高精度

实际选型还应比较 **IQ2 单卡 → IQ3 + helper**，而不只比较同一量化有没有双卡加速：

| 指标 | IQ2 单卡 | IQ3 + helper | 变化 |
| --- | ---: | ---: | --- |
| 长提示 decode（tok/s） | 91.5 | 87.6 | 约 -4.3% |
| 长提示 prefill（tok/s） | 1,155.8 | 1,084.0 | 约 -6.2% |
| 短提示 TTFT（s） | 0.965 | 1.437 | 约 +0.472 s |
| 长提示 TTFT（s） | 22.971 | 24.494 | 约 +1.523 s |
| Engine RSS 峰值（GiB） | 35.23 | 43.10 | 约 +7.87 GiB |
| 两卡总 GPU 平均功耗（W） | 261.05 | 268.69 | 约 +7.64 W |

这支持把空闲 A2000 看作**量化精度与能力余量的增益资源**：更高精度模型可维持接近原来的输出速率，而不是给 IQ2 再叠一张几乎没有收益的卡。“速度几乎一致”在这里主要指 decode；短请求 TTFT 的约半秒代价、额外内存和副卡占用应按实际角色权衡。

### 实际起点是 Thor 27B 的聊天响应

当前使用观察是：原先承担聊天的 Jetson AGX Thor / Qwen3.8-27B 响应偏慢，希望把快速响应职责交给更合适的 MoE。这个产品替换场景的主基线是**现有 Thor 27B 聊天服务**，IQ2 单卡只是 Strata 内部的速度与回退参照。

本工作流认为 IQ3 helper 相对 IQ2 单卡增加的约 0.47 秒短提示 TTFT 可接受，因而不把它作为否决精度升级的条件。优先评估的是能否更快给出正确、可用的聊天答案，并减少不必要的长思考与等待；不是从已经足够快的两个 Strata 档位中机械地挑最低 TTFT。

“Thor 27B 偏慢”属于使用观察。当前数值表没有对 Thor 做同请求 A/B，不能据此宣称 Strata 相对它快了多少倍。后续需记录响应开始、有效答案完成、thinking、排队和修正开销，才能把体感问题归因到具体环节。

### 分享对话中提到的评分是什么

评分已核对到量化作者的[固定 revision 模型卡 Results](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/blob/ed59f92082b1e93c0e96d60a8b11aab089b52f09/README.md#results)。下面是**作者报告的公开评测**，不是本次 NUC / Strata 实验测得的质量分数：

| 版本 | Transformer 平均 bpw | ZS avg | AIME25 | GPQA-Diamond | LiveCodeBench v6 | Task avg |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| BF16 | 16.00 | 76.94 | 100.00 | 91.92 | 87.43 | 93.12 |
| Q2_0 | 2.40 | 78.00 | 96.67 | 89.39 | 81.14 | 89.07 |
| IQ2_XS | 2.50 | 77.16 | 96.67 | 87.37 | 83.43 | 89.16 |
| IQ3_XXS | 3.00 | 77.23 | 100.00 | 91.41 | 86.29 | 92.57 |
| IQ3_S | 3.50 | — | 100.00 | 92.93 | 86.86 | 93.26 |

`Task avg = (AIME25 + GPQA-Diamond + LiveCodeBench v6) / 3`，即三项数学、专家问答和代码评测的等权平均。另列的 `ZS avg` 是 `arc_easy`、`arc_challenge`、`hellaswag`、`winogrande`、`piqa` 五项 zero-shot 任务的平均，**不参与 Task avg**。

IQ3 的 Task avg 比 IQ2 高 3.41 分，接近 BF16；作者报告的归一化回收率约为 99.4%，IQ2 约为 95.7%。这为精度升级提供了公开质量依据，但回收率不是本地任务通过率，也不是“保留了 99.4% 的所有能力”。作者明确将略超 BF16 的部分得分解释为评测波动，而不是量化使模型变得更强。

这些分数尤其适合观察难题上的量化损失，却没有给本地 chat、工具使用或按计划执行划定统一及格线。IQ2 与 IQ3 在 ZS avg 上接近，也不能单凭此推断两者在中文或具体操作任务上必然相同。这张表只比较 Flash-Next 的量化版本，不给 Thor 27B 或未来 dense 模型评分。选型应同时保留公开质量证据、本地运行代价和角色任务通过情况。

## 52 GiB：IQ2 normal 与 IQ3 resident

服务及 engine 使用独立 transient scope：`MemoryMax=52G`，实际 `memory.max=55834574848` bytes；`MemorySwapMax=0`。两个配置均为 Titan 单卡，其余请求参数与约 26K 长提示保持相同。

| 配置 | TTFT（s） | Prefill（tok/s） | Decode（tok/s） | 稳态 RSS 峰值（GiB） | Cgroup 内存峰值（GiB） |
| --- | ---: | ---: | ---: | ---: | ---: |
| IQ2 normal | 23.35 | 1,137.5 | 78.0 | 35.22 | 50.82 |
| IQ3 resident | 28.75 | 922.3 | 72.3 | 51.77 | 52.00 |

两组均无 OOM、无 OOM kill。IQ2 的 `memory.events.max=0`；IQ3 resident 为 360，表示运行中触及上限并发生回收压力，不等同于 360 次 OOM。

IQ3 resident 的 page-locked cache complement 为 **26.11 GiB**，用于 GPU 主缓存之外的 CPU 专家。该版本可直接映射 native GGUF，无需 `experts.bin`。请求日志报告没有从 file tier 读取专家 blob，但启动与缓存填充仍读取模型文件；不能据此声称“完全没有磁盘读取”。

resident 稳态各项独立峰值约为 `RssAnon=2.09 GiB`、`RssFile=22.98 GiB`、`RssShmem=27.02 GiB`。这些峰值未必同时发生，不能相加。RSS 含文件映射与共享内存，cgroup 还计入文件缓存等；二者都不能简单解释成不可回收的专家内存。缓存的可回收性和跨 scope 计费归属也影响比较。

因此，本负载下 IQ3 resident 能在 52 GiB 上限内运行，但没有展示比 IQ2 normal 更好的总占用余量或吞吐。也不应把 IQ2 的 unbounded 与 budget decode 差异全部归因于内存限制：这两组输出长度、nonce、路由及推测解码状态存在差异。

## 128K 配置的容量检查

使用 IQ3 resident、Titan 单卡、`--max-context 131072 --kv-resident 32768`，继续施加 52 GiB 上限和禁用 swap。KV 使用 pinned RAM 保存，VRAM 驻留窗口设为 32K cells；这不是只把配置文件里的 context 数字调大后测一个短提示。

提示在 scope 外用固定版本的 Strata Tokenizer 和实际 ChatTemplate 计数；在文本中段插入 passkey，每个长度只请求一次，`max_tokens=64`。

| API 实际输入 token | `cache_n` | Passkey | TTFT（s） | Prefill 耗时（s） |
| ---: | ---: | --- | ---: | ---: |
| 59,995 | 0 | 正确 | 63.75 | 63.48 |
| 119,972 | 0 | 正确 | 136.44 | 135.90 |

两次均正常结束，无 OOM/OOM kill；结束后 scope 为 `inactive/dead`、结果 `success`，显存回到基线。这验证了本配置在这两个长度上的容量与中段检索，不证明满 131,072 token、不同 needle 深度、多会话或长期运行质量。

## 128K 双卡专家辅助评估

2026-10-09 复用日常 IQ3 helper：Titan 为 `gpu=0`，A2000 通过
`--expert-cache-device1 auto --remote-expert-opt` 提供专家缓存，不使用 layer split。
在原 32K 配置上将 `--max-context` 改为 `131072`，追加
`--kv-resident 32768`，继续使用 int8 KV、52 GiB cgroup 上限和禁用 swap。
请求均为单路顺序执行、`temperature=0`、`reasoning_effort=none`。

### 检索与长输出

独立容量矩阵对 60K、96K、120K 输入分别测试 10%、50%、90% needle 深度各两次，
另对约 126K 输入的 50% 深度测试两次。20 次响应均返回正确 passkey，`cache_n=0`：

| 目标输入 | 样本数 | TTFT 范围（s） | TTFT 平均（s） | Prefill 范围（tok/s） |
| ---: | ---: | ---: | ---: | ---: |
| 60K | 6 | 55.66–56.88 | 56.42 | 1,059.3–1,083.0 |
| 96K | 6 | 92.14–92.50 | 92.34 | 1,042.3–1,046.4 |
| 120K | 6 | 119.88–120.41 | 120.13 | 1,000.9–1,004.9 |
| 126K | 2 | 128.59–128.61 | 128.60 | 983.7–984.3 |

在约 120K 输入后要求持续输出，512、2048、4096 token 三组都精确达到请求上限，
收到 `[DONE]` 并以 `finish_reason=length` 结束。4096-token 组的总 token 为 124,072，
TTFT 119.74 秒、总耗时 161.93 秒、引擎报告 decode 97.1 tok/s。

### 32K 回归与持续运行

相同 helper 分别以 32K 和 128K 配置运行原性能/质量 sanity 集。两组各三次短请求、
三次约 26K 请求和两道质量题均通过结构与流式完整性检查：

| 请求 | 32K TTFT 平均（s） | 128K TTFT 平均（s） | 变化 |
| --- | ---: | ---: | ---: |
| 约 80 tokens | 1.392 | 1.442 | +3.6% |
| 约 26K tokens | 24.368 | 26.059 | +6.9% |

随后在同一 128K 实例上运行 14 个循环，每轮为短请求、60K passkey、短请求、
120K passkey和 60 秒空闲，共 56 分钟、56 个请求。全部响应有效且答案正确；前后半程：

| 请求 | 前半程 TTFT 平均（s） | 后半程 TTFT 平均（s） |
| --- | ---: | ---: |
| 短请求 | 0.471 | 0.461 |
| 60K | 56.020 | 56.027 |
| 120K | 119.683 | 119.752 |

进程 RSS 峰值约 45.47 GiB，前后四分之一的 RSS 均值仅增加约 0.17%。cgroup
达到 52 GiB 上限，但 soak 期间 `memory.events.max` 只增加 281，`oom=0`、
`oom_kill=0`；主机最低 `MemAvailable` 约 13.24 GiB。显存峰值为 Titan 23,678 MiB、
A2000 10,793 MiB，温度峰值分别为 84°C 和 74°C，未触发预设的 86°C 停止线。
`nvidia-smi` 有少数瞬时功耗读数超过配置 power limit，不能将其当作可靠墙上功耗；
若后续以功耗作为发布门禁，应使用独立测量或确认驱动的采样语义。

### 取消恢复与边界

- 120K prefill 启动 10 秒后断开客户端，紧接的短请求 TTFT 为 4.18 秒；后端没有继续占满约 120 秒的原请求。
- 一个 120K 请求运行时排入第二个 120K 请求，5 秒后取消排队客户端；首请求结束后短请求 TTFT 为 0.56 秒，说明已取消的排队请求没有随后执行。
- 这些实验验证的是直接 loopback 后端、单请求 FIFO 和关闭 thinking 的路径。尚未验证 LiteLLM/Tailnet/OpenCode 的 128K 元数据、生产默认 low thinking、多客户端并发或服务重启后的长期运维行为。
- 若进入产品试用，可先声明 context 131,072、输入预算 122,880、输出预算 4,096，保留约 4K 给模板、工具和 token 估算误差；正式模型仍应在产品路径门禁通过后再切换。

## 复现实验配置

以下命令在固定 Strata 源码目录、已经准备好的 CUDA/FHS 环境中执行。GPU 编号需先确认 Titan 为 0、A2000 为 1。

```bash
git checkout --detach d5ea7133741e67743c0e886bb426c0ce8d69cf6c
export HF_ENDPOINT=https://huggingface.co
export STRATA_MTP_REVISION=de4b8e4d43b917e7706784d8bb445c9af86a3540
export STRATA_DATA="$HOME/strata-data"

./setup.sh --setup --yes --build --backend cuda --cuda 13 \
  --source huggingface --family qwen --model IQ3_XXS \
  --gpus 0,1 --layer-split auto --context 32768 --kv int8 \
  --low-ram off --vision no --no-browser --no-start \
  --host 127.0.0.1 --port 8080 --data-dir "$STRATA_DATA"
```

IQ2 基础配置将 `--model` 改为 `IQ2_XS`。已校验的两个 GGUF shard 可通过 `--gguf-dir` 指定，避免重复下载。setup 生成 `strata-iq2_xs.json` / `strata-iq3_xxs.json`；它们默认是上面请求的自动分层配置，单卡和 helper 需要生成副本。

### GPU 模式

- **Titan 单卡**：配置 `gpu=0`，删除 `layer_split`；保留模型、profile、MTP、context 和其余参数。
- **自动分层**：配置 `gpu=[0,1]`、`layer_split="auto"`。两卡各有权重、session 和缓存开销，不是单卡 36 GiB 显存池。
- **纯专家辅助**：配置 `gpu=0`，删除 `layer_split`，在 `env` 中覆盖 `CUDA_DEVICE_ORDER=PCI_BUS_ID`、`CUDA_VISIBLE_DEVICES=0,1`；保留主 cache/profile，并追加 `--expert-cache-device1 auto --remote-expert-opt`。

最后一种配置中的 `gpu=0` 与 `env` 覆盖都必要：HTTP wrapper 遇到 `gpu=[0,1]` 且没有 `--peer-device` 时会自动加 layer split；仅删除 `layer_split` 字段不够。固定版本的 `child_env()` 会先按 `gpu` 设置可见设备，再应用配置的 `env`，因此上面的覆盖让引擎仍能使用 CUDA1。Helper cache 参数的数字单位是专家 slot 数，不是 GiB；`auto` 按副卡剩余显存计算。

本次 helper 使用 host staging 路径，不要求 P2P；它与 `--peer-device`、`STRATA_PREFILL_HELP` 是不同功能，不应混为一谈。

### Resident 与长上下文

从原始 IQ3 配置生成 Titan 单卡副本，在 `args` 中追加 `--resident-experts`。本次 pack 有 `native_experts.txt`，同时提供 `--native` GGUF 路径；引擎的 `FileExpertSource::open_gguf()` 可直接使用它们。

不需要为了这个 native resident 实验重跑 `setup --low-ram resident`：该版 setup 会在 pack 缺少 `experts.bin` 时 materialize 约 42.9 GB 的专家文件，而这不是本次引擎路径的前提。

128K 副本把 `--max-context` 的值改为 `131072`，并追加 `--kv-resident 32768`。引擎没有单独的 `--kv-streaming` flag；setup 的 `--kv-streaming on` 会生成上述 KV resident 参数。该版 setup 的 auto 判断只读物理 `MemTotal`、不读 cgroup 上限，不能代替容量实测。

在已准备的 FHS 环境中，从源码工作目录启动副本：

```bash
systemd-run --user --scope -p MemoryMax=52G -p MemorySwapMax=0 \
  .venv/bin/python serve/server.py --engine strata \
  --config strata-iq3-resident-128k.json --port 8080
```

配置副本的日志路径应独立于基准原始日志。健康检查除了 HTTP 200，还需确认 `/health` 的 `loaded=true`；结束时向服务 Python 发 SIGTERM，等待它清理 engine 及显存。

## NixOS 构建与运行发现

本次在临时 FHS 环境中源码构建，没有生成常驻系统服务。该版 release 没有 Linux 预编译 engine，不能将 setup 中的 Linux 下载名称当成资产确实存在的证据。

- 精简 CUDA 环境需要 `cuda_nvcc`、**`cuda_crt`**、`cuda_cudart`、`cuda_cccl`、`libcublas` 和 CUDA 包集的 host compiler。遗漏 CUDA 13 拆出的 `cuda_crt` 会报缺少 `crt/host_config.h`；不必引入整套 cuSPARSE/cuSOLVER/cuFFT/NPP。
- CMake 与 NVCC 需能找到合并后的 toolkit root、头文件和 cuBLAS；运行时使用宿主 `/run/opengl-driver/lib` 的驱动库，不使用 toolkit stubs 代替驱动。
- `buildFHSEnv.env` 是交互 `nix-shell` 入口。本次 `nix-shell --run` 没有把目标命令带入 FHS，改为构建 `buildFHSEnv` 可执行 wrapper，再显式传 `-c` 才正确执行。
- 为 managed Python 显式设置 `SSL_CERT_FILE` 与 `REQUESTS_CA_BUNDLE` 到 Nix `cacert`，解决 TLS issuer 验证失败。
- `--source huggingface` 不会覆盖已有的 `HF_ENDPOINT`；MTP 下载源要显式设置 endpoint。本次最终使用官方源，并固定 MTP revision。
- setup 在指定的 HF revision 不存在时可能回退到 `main`；复现时应检查下载日志与文件哈希，不能把回退后的文件当成同一实验。
- 端口关闭后的 `TIME_WAIT` 不代表服务还在运行。自动顺序测试的 bind 探测使用 `SO_REUSEADDR`，同时仍拒绝真正的 listener；恢复测试保留已完成组，不混入失败尝试的半成品样本。

## 解释边界与后续

本次两道中文/代码题主要是运行 sanity check，不能识别完整的量化质量差异。公开难题评测给出了升级 IQ3 的理由，本地测量给出了硬件代价；二者都不能替代特定角色的可用性验证。

### 按模型分层评估，而不是要求所有本地模型全能

后续考虑如下分工，这是评估目标，不是已部署的模型路由：

| 角色 | 输入与职责 | 主要验收依据 |
| --- | --- | --- |
| 云端模型：Roadmap 规划者 | 需求、长期目标、约束；制定阶段方向和优先级 | 人工检查依赖、取舍、遗漏与阶段可验收性 |
| 大 dense：实现改动规划者 | 已确定的阶段目标与代码上下文；提出具体修改计划 | 目标文件、接口、不变量、验证步骤是否充分且可执行 |
| 小 dense：具体操作者 | 明确计划与范围；完成指定改动和验证 | 测试通过、diff 符合范围、能正确处理反馈；不要求独立重做 Roadmap |
| 快速 MoE：chat / 快速响应 | 日常问答、材料解释、轻量整理；有工具时按既定协议使用 | 给定材料内的正确性、指令遵循、有效响应延迟；工具能力只在实际需要时验收 |

除承担复杂改动规划的大 dense 外，本地角色首先需要“足够胜任分配的工作”，不必统一追求难题榜单最高分。模型结构是这里的分工偏好，验收仍看任务本身。复杂目标、不完整计划或超出职责的问题应转交上层，而不是在快速响应层无限尝试。

这与 [Agentic / models](../../agentic/models/README.md) 已有的能力不足或长时间不收敛时转交原则衔接。各角色的具体门槛、允许修正轮次与截止时间仍应在工作流评估前确定，不能从 Task avg 直接换算。

### 从小型、可判分的材料起步

已有 [Thor fixtures](../thor/benchmark/fixtures.json) 和 [held-out fixtures](../thor/benchmark/held-out.json) 可复用判分结构，无需先造一套覆盖所有能力的大 benchmark。以下是后续评估建议，**尚未作为 Strata 质量实验执行**：

| 用例 | 适用角色 | 可判分依据 / 复用起点 |
| --- | --- | --- |
| 严格短回答 | 快速 MoE | 精确答案、无多余格式；`exact-short-output` |
| 中文材料摘要与解释 | 快速 MoE | 预先列必需事实、输出约束和材料缺项；逐项判定，不以文风代替正确性 |
| JSON 输出 | 需要结构化交付的角色 | 可解析、目标字段和值；`strict-json-schema`，按实际需求补类型和额外字段检查 |
| 工具调用与结果续接 | 实际使用工具的角色 | `tool-get-weather` 的函数名/参数 gate；另补工具返回后的事实使用与最终回复检查 |
| 按要求修复小函数 | 小 dense 操作者 | `python-interval-repair-ast` 的测试和输入不被修改要求；不作为 chat-only 模型的必考项 |
| 计划内的最小仓库改动 | 小 dense 操作者 | 使用脱敏小仓库和固定计划，检查验证结果、diff 与是否擅自扩大任务 |
| 缺资料时的澄清 / 转交 | 各本地角色 | 预先定义可继续、需补充和需上层规划的情形；不把编造方案计为完成 |

每类分别记录**首次通过、允许修正后的通过、错误类型、转交次数、有效完成耗时**，再对角色真正需要的能力设置 gate。复杂规划题采用人工 criteria；能精确验证的题用答案、结构或测试，不用另一模型的总体印象分替代。

能力 gate 达到后再比较性能：chat 看首个有效回答，工具角色看首次可用调用，操作者看验证完成的耗时；TTFT 和 tok/s 是解释这些耗时的辅助指标。样本少时报告每题结果与修正记录，不宣称统计显著或用不稳定的 p95 作决策。

第一轮主对照是 **Thor Qwen3.8-27B 现有聊天配置 → Strata IQ3 helper 快速响应候选**。先用同类请求比较实际产品配置，判断等待与可用答案耗时是否改善；再按各后端真实支持的参数匹配并确认 thinking 行为、提示长度、回答预算和缓存条件，做诊断对照。前者评估工作流替换效果，后者帮助解释模型、推理设置和后端开销，不将二者混成一个加速倍数。

IQ2 单卡与 IQ3 helper 的配对仍用于判断 Strata 内部的精度升级价值以及 A2000 不可用时的回退。锁定工具协议及修正预算，保留少量 held-out 题，避免围绕已知答案调参。如果两者都满足快速响应角色的门槛，IQ3 是可用余量而非必需升级；如果 IQ3 能减少返工或上层介入，才把公开质量提升兑现为本地能力收益。

### 三项补测的执行准备（WIP）

当前安排先暂缓第 1 项 Thor 替换 A/B：在 NUC 重启后确认 GPU、驱动与加载状态，先试用 IQ3 helper 收集实际问题。第 2、3 项的材料和协议保留，按试用反馈决定先补哪一项；不把一次正常聊天当作完整接入或稳定性测试通过。

先准备 chat-only 的[合成用例](benchmark/fixtures.json)，不要求快速 MoE 独立规划大改动或执行生成的代码。用例包含可精确判分的回答与需要人工逐项评阅的中文交付；人工项在评阅前必须保持待判，不能自动算通过。实际日常材料尚未收集，这套 starter 只用于跑通协议与初步筛查，后续应替换部分题目为脱敏的真实请求。

#### 重启后的试用准备

模型、pack、MTP 与启动配置保存在磁盘；重启后重用这些文件，但仍需启动服务并重新加载权重。先确认 GPU 编号/PCI 顺序符合配置预期：Titan 为 CUDA0、A2000 为 CUDA1，驱动可用且内存满足普通 IQ3 模式，再启动已验证的 32K helper 副本。浏览器开始聊天前，检查 `/health` 返回 `loaded=true`。

初次试用采用内置 Web Chat。Loopback 服务可通过临时 SSH 转发接入；下面的命令在**浏览器所在电脑**运行，目标使用者自行设置，不写入公开记录：

```bash
ssh -N -L 18880:127.0.0.1:8080 "$STRATA_SSH_TARGET"
```

打开 `http://127.0.0.1:18880/`，使用同一来源的页面和相对 API 路径，无需为此修改 CORS 或生产路由。

**日常试用先选择 low**：输入框旁齿轮 **Sampling and thinking → Thinking: Low → Apply**。固定版本 Web UI 在新浏览器默认选择 high，并随请求显式发送档位；Low 对应 `reasoning_effort=low`。诊断对照的 Off 才对应 `none`；`Show thinking` 只是显示开关，不会调整思考档位。该选择保存在浏览器来源的 `localStorage`，同浏览器、同来源会沿用；不同访问来源需重新确认。

源码中没有可用的 run config 字段或 URL 参数代替这个 Web UI 选择。**Use for other apps too** 可保存服务器共享默认值，但不能覆盖 Web Chat 每次显式发送的选择；后续 API/客户端接入仍应明确快速聊天的 thinking 设置。

先从日常问答、材料解释、摘要、多轮更正与取消开始体验；出现问题时保留题目、当时的档位、错误表现和等待环节，后续再整理为脱敏用例。Thor 对照和半小时自动循环不在这个重启准备步骤中启动。

#### 1. 替换 Thor 27B 聊天的效果

保留三条清楚标记的路径：

| 路径 | 目的 | Thinking 控制 |
| --- | --- | --- |
| Thor 现有聊天配置 | 实际产品基线 | 记录实际生效值；此前默认 low，本轮发布准备改为模板开启 thinking、effort medium |
| Thor 关闭 thinking | 判断等待中有多少来自思考策略 | `chat_template_kwargs.enable_thinking=false`；不能假定顶层 `reasoning_effort` 对此路由有效 |
| Strata IQ3 helper 日常配置 | 快响应替换候选 | 默认 low；关闭 thinking 的请求单独作为诊断对照，不采用 API 未指定时的 xhigh 默认 |

先确认模型已加载并预热一次，再按同一题目配对运行，首批每题 2–3 轮。不同路径轮换顺序，记录实际输出和提前 EOS，不把重复同一道题当作更多独立能力样本。

产品基线保留其实际输出预算，并给候选合理的同类交付预算；模板诊断对照再统一输出上限。Thinking 也消耗输出 token，如果机械地给开启 thinking 的路径一个很小的上限，可能截断在答案之前；这类结果应标截断，不能当成模型不会回答。

逐请求保留首个 generation、首个 reasoning、首个 content/工具输出、`[DONE]`、usage、finish reason 和可用 timings。首个 content 不等于正确答案已经交付；通过用例 gate 后的完整回答耗时才计入“有效完成耗时”。Reasoning 缺字段时记录缺失，不推算思考时间。

先走明确的模型 ID，不用自动故障切换别名改变测试对象；实际客户端与直连后端的结果分开标记。Thor 现有客户端有路由，Strata 目前只有 loopback 实验服务，客户端入口尚需准备。首批可用临时 SSH 转发和测试进程配置接入，保持生产路由不变；URL 与用户 API key 只从运行环境取值，不进入公开 fixtures 或报告。

#### 2. IQ2 与 IQ3 的本地能力余量

复用同一套题和 gate，对照 IQ2 Titan-only 与 IQ3 helper，统一关闭 thinking。JSON/精确答案逐项判分，中文项按固定 criteria 人工评阅；分别报告首次通过、有限修正后通过、错误类型和完成耗时，不合成一个未经标定的总分。

若第一项的 IQ3 配置、输入和预算完全一致，可复用那些结果，只新增 IQ2 样本。需要客户端自动修正时，应另做限定轮次的实验；直接 API 一次答复不能冒充完整 Agent 收敛验证。

现有用例使用 Thor fixture schema，带有显式关闭 thinking 的模板意图。Strata 需要后端适配器将意图转为它实际支持的参数；当前 Thor runner 的 runtime/profile 校验也不能拿来证明 Strata 运行时一致。材料可复用不等于跨后端执行器已经完成。

#### 3. 接入、取消、排队与持续运行

| 场景 | 测试动作 | 需要观察的结果 |
| --- | --- | --- |
| 流式响应 | 一次短请求经直连、再经实际客户端/路由 | reasoning/content 分离、流式到达与完整结束；不把 UI/网关缓冲误算为后端生成速度 |
| 多轮 | 把实际生成的 assistant 回复加入后续 messages，再做追问和更正 | 用户最新要求生效、旧信息未误覆盖；静态多消息题只验理解，不证明真实客户端传递历史 |
| 活跃请求取消 | 长 prefill 或输出过程中关闭 SSE，再发短请求 | 客户端关闭时间、后端请求结束证据、短请求恢复耗时；不以客户端停止收数据代替后端已停止 |
| 等待请求取消 | 长请求运行时排入第二个请求，再取消第二个 | 等待项是否移除、是否稍后仍执行、队列是否恢复 |
| 长短混合 | 同一段长输入运行时提交一个短聊天，对照孤立短请求 | 短请求额外等待及完成耗时；记录真正的队列/后端证据，不从 TTFT 独自推算排队时间 |
| 30 分钟持续使用 | 低负载串行循环短请求和多轮，间隔留空闲 | 有效完成数、错误、取消恢复、截断，以及预热后内存/队列趋势；缓存增长不自动判为泄漏 |

长输入先选约 12K–24K token、预留回答空间，并记录两后端的实际 usage；不一开始就施加 120K 压力。Strata 当前 helper 未启用并行 batch，是单请求 FIFO；Thor 生产配置允许最多 4 个运行请求但共享 token 池。因此先按实际配置测等待体验，再把更改 parallel 或长任务路由作为独立实验，不能悄悄改变配置后混合结果。

取消检查应尽可能读取直接后端状态；网关健康不等于模型已空闲。状态不可观察时应标“后端取消未确认”。取消一个请求也不要求卸载模型，正常保留权重与缓存的显存不算泄漏。半小时场景最后执行，在短请求、结束标记及取消恢复基本通过后再开始，不持续累积新的并发请求。

**执行器缺口**：现有 Thor 工具已有 SSE 计时、gate 和 `followups`，但缺跨后端参数/runtime 适配、程序化取消确认、并发长短请求编排与 soak 控制。这些场景尚未执行，不能把只关闭连接或只跑通数据校验写成已通过接入测试。

这些补测均可在 A2000 保持安装的情况下完成；IQ2 单卡仍用 CUDA 可见性限制。物理移除 A2000 后的 Titan lane 宽度、功耗与散热变化另排窗口，不包含在本轮角色评估中。

游戏 VM、A2000 直通与自动切换仍属于后续工作。本次只证明独立推理配置可启动、响应及释放资源，没有验证在途请求、会话或 KV cache 在切换时无缝保留。

## LiteLLM 接入准备

准备的客户端 alias 为 `strata/qwen3.8-flash-next`，对应 IQ3 helper、32K 上下文的文本聊天，默认思考 low。共享 [客户端模型表](../../../modules/home/beacoworks-models.nix) 声明 context 32768、output 4096，开放 reasoning 档位，不声明视觉能力；LiteLLM 输入预算为 28672，给输出预留 4096。思考输出也计入回答预算，模板及工具开销应计入总上下文。

新增 [strata-runtime](../../../packages/strata/runtime.nix) FHS 包只提供已准备 engine/venv 所需的 Python、CUDA runtime/cuBLAS、C++ runtime 和 CA 环境，不下载或打包模型。GGUF、pack、MTP、venv、配置和日志留在运行机器的磁盘上，不能将这些文件直接读入 Nix derivation。

主机侧准备为 systemd 管理的 loopback 服务，再通过 Tailnet TCP Serve 提供入口。NUC 使用 userspace Tailscale，不能照搬 Thor 的 `tailscale0` 地址绑定 socket。集群侧沿用 Tailscale Operator ExternalName Service，LiteLLM 只访问集群 Service DNS；主机访问地址和 Terraform 清单属于私有仓。

LiteLLM 使用标准 OpenAI-compatible provider。日常路由的 `litellm_params` 设置可覆写默认值，而不是在固定 `extra_body` 中锁死 effort：

```json
{
  "reasoning_effort": "low",
  "allowed_openai_params": ["reasoning_effort"],
  "extra_body": {
    "chat_template_kwargs": {
      "enable_thinking": true
    }
  }
}
```

在 LiteLLM 1.90.0 Router、全局 `drop_params=true` 的本地 HTTP mock 中，流式与非流式默认请求得到有效 low；Pi 模板参数显式选择 medium/off、OpenCode 顶层参数选择 medium/none 也均通过最终 payload 与固定 Strata frontend 解析验证。`extra_body` 会展开到后端请求体，allowlist 防止显式 effort 被过滤。这证明参数路径，尚不代表生产网关已接通。

不要同时给 Strata 放一个固定的顶层 effort 和嵌套的默认 `chat_template_kwargs.reasoning_effort=low`：固定版本的 `effort_kwargs()` 对 low/medium 只设置 effort，不设置 `enable_thinking`，嵌套 low 仍可能覆盖显式 medium。当前配置把默认 effort 放在 Router 可覆写的部署参数，嵌套模板只开启 thinking，因此两类客户端都可控制档位。

Thor 的明确 27B 路由及 auto 路由的 NixOS 27B 成员默认模板档位改为 medium，保留 `preserve_thinking=true`；Pi 的显式 low/off 不改为 medium。AstrBot 持久配置中还发现了 Thor 条目的显式 low，这会压过网关默认值；本轮准备一项启动前的一次性 low→medium 迁移，不改选模、其它 provider 或后续用户自行选择的档位。当前群聊实际选模尚未确认。

该调整用于改善群聊上下文判断的使用问题，不证明根因已经定位或问题已经修复；发布后应以脱敏的称呼、引用、代词指向和多轮群聊样例回归，同时确认实际输入中包含相应上下文。

OpenCode 的模型级默认值分别为 Strata low、Thor 27B medium，显式 variants 另行选择；Thor 还直接发送 `chat_template_kwargs`，不能只依赖 SGLang 不消费的顶层 effort。OpenCode 1.18.34 的隔离 mock 已捕获这些字段，Pi 沿模型表的模板兼容映射生成请求。Home Manager 激活后需重启 OpenCode 加载新配置，运行中的旧会话不热更新。原生 Strata 已通过一次基础工具调用 smoke；实际客户端工具结果续接仍待补测。

启用顺序是：公开 runtime/客户端登记进入私有仓锁定的基线 → 准备好运行机上的模型 artifacts → 在迁移窗口由 systemd 接管临时进程并确认 `loaded=true` → 启用 Tailnet/集群代理并验证可达性 → 应用 LiteLLM 声明并用用户模型 API key 测试。

路由超时和 stream timeout 按现有本地模型设置为 2400 秒，`num_retries=0`；取消、排队以及客户端实际体验仍按前述协议补测。Terraform 应用还会把新 alias 加入现有“所有已登记模型”虚拟密钥的模型列表，应在部署 diff 中确认该权限变化。

## 固定版本参考

- [Strata README](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/README.md)
- [安装器与配置生成](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/setup.py)
- [多 GPU 分层](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/docs/MULTI_GPU.md)
- [第二 GPU / 专家辅助](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/docs/SECOND_GPU.md)
- [HTTP wrapper](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/serve/server.py)
- [Web Chat 参数与本地存储](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/serve/web/app.js)
- [Native expert source](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/src/core/expert_source.cpp)
