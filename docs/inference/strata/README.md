# Strata：Titan RTX / A2000 推理实验

2026-10-08（Asia/Shanghai）实测：在 64 GiB 内存的 x86 NixOS 平台上，比较 Qwen3.8-Flash-Next 的 `IQ2_XS` 与 `IQ3_XXS`、单卡与两种双卡模式，以及 52 GiB 内存预算下的 resident 模式。最后验证 128K 配置下的长文本检索。

这是历史实验记录，不代表当前生产部署。数值、范围、文件哈希与资源采样汇总见 [results.json](results.json)。

## 结论

- **默认优先 IQ2_XS + Titan 单卡**：本次无额外内存上限的长提示测试中，prefill 约 1,156 tok/s、decode 91.5 tok/s。
- **使用 IQ3_XXS 时，A2000 适合做专家缓存辅助**：decode 从单卡 75.9 提升至 87.6 tok/s，prefill 基本持平；测试期间两卡总 GPU 平均功耗增加约 12 W。
- **当前自动分层不适合作为这组异构 GPU 的默认方案**：两种量化的长提示 prefill 均明显慢于单卡。该结论针对本次版本、自动放置和负载，不排除其他手动分层方案。
- **52 GiB 预算下，优先 IQ2 normal**：IQ3 resident 可运行，但较慢，且“26.1 GiB 专家常驻池”不等于总内存需求。
- **IQ3 resident 的长上下文有可运行路径**：128K 配置、52 GiB 上限、禁用 swap，约 60K 与 120K token 输入均找回中段 passkey；这不是长期稳定性或综合质量评测。

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

两道中文/代码质量题不足以证明 IQ3 的回答质量显著优于 IQ2。更高量化位宽、吞吐和本次质量样本分别记录，不将它们自动合并成质量排名。后续若把配置用于实际助手，应补任务集、长时间稳定性及并发测量。

游戏 VM、A2000 直通与自动切换仍属于后续工作。本次只证明独立推理配置可启动、响应及释放资源，没有验证在途请求、会话或 KV cache 在切换时无缝保留。

## 固定版本参考

- [Strata README](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/README.md)
- [安装器与配置生成](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/setup.py)
- [多 GPU 分层](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/docs/MULTI_GPU.md)
- [第二 GPU / 专家辅助](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/docs/SECOND_GPU.md)
- [HTTP wrapper](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/serve/server.py)
- [Native expert source](https://github.com/Niko1221/Strata/blob/d5ea7133741e67743c0e886bb426c0ce8d69cf6c/src/core/expert_source.cpp)
