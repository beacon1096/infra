# AstrBot → Multica 中继

AstrBot 是任务入口，不承担基础设施运维。它只能通过受限的本地中继创建 Multica Issue；AstrBot 容器不持有 Multica 凭据、NixOS shell、仓库写权限或集群凭据。中继固定在 Beacoworks 工作区，仅通过挂载到 AstrBot 容器的 Unix socket 提供 Issue 创建能力。AstrBot 工具还要求管理员身份，并提示模型在创建前展示标题和描述供确认。

当前初始 PAT 属于 `beacon1096`，名称为 `astrbot-relay-temporary`。专用成员 `astrbot.no-reply@beacoworks.xyz` 注册完成后应替换它。Multica 全局注册仍关闭；若邮件投递不可用，允许注册的账户须请求验证码，由能查看万象集群日志的运维人员从后端 `[DEV] Verification code` 日志取得。专用账户应仅作为工作区成员；其 PAT 用 sops-nix 保存，绝不挂载到 AstrBot。新凭据部署并验证后撤销临时 PAT。

## 能力边界

不要暴露无限制的 Multica CLI，也不要让模型输出拼接成 shell 命令。只为批准的动作添加独立的管理员工具，例如 Issue 创建、读取、搜索和评论；不开放 Agent 分配、任务重跑、autopilot、运行时管理、删除或任意 CLI 参数，防止今后 CLI 新增命令时静默扩大权限。

AstrBot 的 `computer_use_require_admin` 只是额外关卡，不是主要的 Multica 权限边界。即使由管理员发起对话，群消息、引用内容、搜索结果和 Issue 描述仍可能包含提示注入。因此凭据留在中继侧，所有特权操作都须由服务端校验。

## 执行沙箱

通用 shell 和 Python 执行使用远端 Shipyard Neo 沙箱，不使用 AstrBot 本地容器运行时。管理员可以使用基于 Nix 的自定义 Ship profile，但须限制 CPU、内存、进程数、存储、存活时间、并发和出站网络；不得挂载宿主 Docker/Nix daemon socket、SSH 或集群凭据、`/run/current-system`、可写宿主 Nix store。

沙箱提供 Nix 和 nixpkgs registry 后，Agent 可临时运行 `nix shell nixpkgs#<package>` 或 `nix-shell -p <package>`。这不意味着任意软件安全：下载和构建仍会消耗网络、CPU、磁盘与时间，并以沙箱权限运行。

AstrBot 4.28 在检查发送者管理员身份之前，就为每个消息会话选择并缓存一个内置沙箱 profile。因此内置 computer-use 工具仅给管理员使用；普通成员使用独立的 `standard_exec` 插件，由独立 Bay 实例和固定 `standard-cli` profile 承载：

- 管理员：在隔离的 Nix 沙箱中执行通用命令。
- 普通成员：只运行标准镜像已预装的软件，执行时间短且串行。
- 标准沙箱：无互联网路由的内部 Docker 网络；0.5 CPU、512 MiB 内存、256 进程、64 MiB cargo 限额、20 秒命令时限、64 KiB 输出上限、60 秒沙箱 TTL。
- 网络能力只经专用 AstrBot 工具开放，例如搜索、视频分析和显式允许的服务中继。

`standard_exec` 每次调用新建沙箱，结束后停止。调用必须串行，因为同一内部网桥上的沙箱仍可能访问彼此的运行时 API；若以后需要普通用户并行执行，应为每个沙箱分配独立 Docker 网络，不能仅靠提示词或隐藏工具说明隔离。

## 模型与思考档位

AstrBot 通过内置 openai 适配器连接共享 LiteLLM 的 `thor/qwen3.8-27b`。该适配器不发任何思考参数（不传 `reasoning_effort`/`enable_thinking`），而 Qwen3.8-27B 的 chat template 默认为 xhigh：动不动就长时间大思考，在默认配置下很难快速跑通，甚至把整个输出预算耗光。

现在两处都固定为低档：

- 网关侧：`thor/qwen3.8-27b` 路由带默认 `chat_template_kwargs`（`enable_thinking: true`、`reasoning_effort: low`、`preserve_thinking: true`），声明于私有仓 `terraform/litellm-wanxiang/models.json`；任何不带思考参数的客户端都会命中。详见公共 infra 的 `docs/inference/thor/thor-inference.md`。
- AstrBot 侧：`cmd_config.json` 中该 provider 的 `custom_extra_body` 也显式写入同样的值。这是运行时状态，不在仓库或 Nix 中，重装系统或清数据会丢；丢失后仍由网关默认兜底。

客户端自带 `chat_template_kwargs` 时覆盖网关默认（已验证），因此不影响显式控制档位的客户端。
