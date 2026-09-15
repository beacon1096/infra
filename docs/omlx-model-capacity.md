# oMLX 自部署模型容量

> **已退役（2026-09）：** M4 上的 oMLX 模型（Qwen3.8-27B-4bit，此前的 Gemma 4 系列）已全部下线，`beacon-mac-mini-m4` 系统配置已移除 oMLX 服务与 `iogpuWiredLimit`。食堂食品卫生事件筛查流程（含 `image-verifier` agent）整体废弃，算力分配见 infra-private `docs/ai-compute-inventory.md`。下文容量规划与复核 Agent 细节仅作历史参考；“Nix 管理”一节对后续 oMLX 模型部署仍然适用。磁盘上的权重（`~/.exo/models`）需手动清理。

## Nix 管理

`darwinModules.omlx` 导出独立的 nix-darwin 模块。`packages/omlx/default.nix` 固定官方 oMLX 应用版本与 DMG 校验值，复用应用内的 Python、MLX 和 Metal 运行环境。在 Mac 上可用 `nix build .#omlx` 单独构建程序。默认包适用于 macOS 26/27；macOS 15 可用 `pkgs.callPackage ./packages/omlx { macosVersion = "15"; }` 设置 `services.omlx.package`。

M4 的 `services.omlx.models` 声明模型仓库、完整 commit revision 和受管推理参数。权重保存在运行目录，不进入 Nix store。新增模型时先在 Mac 上构建并下载，再应用服务配置：

```bash
nix build .#darwinConfigurations.beacon-mac-mini-m4.config.system.build.omlx
./result/sync/bin/omlx-sync --download-only
sudo darwin-rebuild switch --flake .#beacon-mac-mini-m4
```

下载会验证固定 revision 的文件大小及内容哈希，完成后才发布模型目录。服务启动前只合并受管的每模型参数，保留其他模型和认证配置；不会自动下载或删除权重。`settings.json` 与 `model_settings.json` 保持可写，不链接到只读 store。

## 当前容量规划

下表记录 Mac mini M4 上的模型容量规划。AGX Thor 的替代部署待确认，暂不列入可用模型。常用请求是日常建议范围；oMLX 硬上限用于拒绝超过本机容量的请求，不代表该长度适合日常使用。

| 模型 | 机器 | 常用请求 | oMLX 硬上限 | 输出上限 |
| --- | --- | ---: | ---: | ---: |
| Qwen3.8-27B dense | M4 | 8–16K | 32K | 8K |
| Qwen3.6-27B dense（保留回退） | M4 | 8–16K | 32K | 8K |
| Gemma-4-31B dense | M4 | 输入约 6K 内 | 8K | 2K |
| Gemma-4-E4B | M4 | 32–64K | 128K | 8–16K |

oMLX 0.6.4 与固定 revision 的 Qwen3.8-27B 4-bit 已在 M4 完成短请求推理验证。网关和 OpenCode 已切换为 `Qwen3.8-27B-4bit`，Paseo 实际请求通过。旧 Qwen3.6 权重保持隐藏并保留回退。

2026-09-13 的合成文本测试中，8,008 和 16,012 token 输入均正确找回开头的校验码，输出为 7 token，分别耗时约 122 和 227 秒；后者复用了 6,144 token 前缀缓存。32,008 token 输入也找回校验码，耗时约 459 秒，复用了 14,336 token 缓存；期间有客户端并发请求并触发内存限流，耗时不能作为单请求基准。这是短输出连通与上下文验证，不代表真实任务质量或 8K 长输出性能。日常建议输入控制在 8–16K，并为输出预留上下文空间。32K 长输入期间并发加载 Gemma E4B 曾被内存保护拒绝，应串行使用这些模型。

## Gemma 4 31B 部署限制

Gemma-4-31B dense 已迁移到 32GB Mac mini M4。其 4-bit 权重实际占用约 17.9GB，而 oMLX 自动模型内存预算约为 25.6GB，只剩约 7.7GB 供 KV cache、图片编码、预填充和 Metal 运行时使用。因此使用 8K 上下文和 2K 输出硬上限。

M4 上的 Gemma-4-31B dense 使用：

- `max_context_window = 8192`
- `max_tokens = 2048`
- TurboQuant KV Cache：开启，8-bit，Skip Last 开启
- Memory Guard：`aggressive`

LiteLLM 与客户端模型元数据同步声明：

- `max_input_tokens = 8192`
- `max_output_tokens = 2048`

图片复核每次限制为一个事件、1–3 张图片。输入文本和图片 token 尽量控制在约 6K 内，为输出预留最多 2K；常规复核通常只需 512–1024 输出 token。不要在 M4 上为该模型开放 16K、32K 或模型声明的 262K 上下文。

Qwen3.6/3.8-27B 与 Gemma-4-31B dense 不能在 32GB M4 上同时常驻，首次切换会包含卸载和加载时间。网关及客户端连通性测试应允许至少 60 秒超时，避免把冷启动误判为不可用。

## Gemma 图片复核 Agent（已退役）

默认 OpenCode Agent 注入的系统提示和工具定义约为 15.8K token，超过 Gemma-4-31B dense 在 M4 上的 8K 安全窗口。不要通过放宽模型硬上限来容纳与图片复核无关的工具定义。

`modules/home/coding-agent.nix` 声明了专用 `image-verifier` primary Agent。该 Agent 固定使用 `beacoworks/gemma-4-31b-it-4bit`，禁用全部工具、MCP 和 skills，只保留精简的食品安全图片复核提示。调用时同时使用 `--pure`，避免加载外部插件：

```bash
opencode run --pure \
  --agent image-verifier \
  --title image-verifier \
  '复核所附图片。' \
  --file=event.jpg </dev/null
```

显式传入 `--title`，避免 OpenCode 额外调用模型生成会话标题。提示词必须位于第一个 `--file` 之前；多图时重复使用 `--file=<path>`。每次只处理一个事件和 1–3 张图片。

## OpenCode 声明

`modules/home/coding-agent.nix` 中的模型上下文和输出限制应采用当前部署的安全硬上限，而不是上游模型的理论窗口。高级 oMLX 推理开关只记录在本文，不写入 OpenCode 的模型使用提示。
