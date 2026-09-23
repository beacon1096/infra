# 通过 LiteLLM 使用 Thor 推理

性能调优冻结在已验证的 Qwen3.8-27B DFlash2 block16 配置。稳定性和基础设施移交优先。

## Agent 连接

- Tailnet 基础 URL：`http://litellm.tail5d550.ts.net:4000/v1`。
- 模型：`thor/qwen3.8-27b`。
- 使用已获该模型授权的 LiteLLM 虚拟密钥。绝不要分发 LiteLLM 主密钥。
- 现有 Nix agent 凭据 `/run/secrets/personal/beacoworks-models/api_key` 已验证可用。其旧版 `/v1/models` 列表返回 `all-team-models`；须明确配置模型 ID，不要依赖自动发现。
- 上下文总量为 **262144 token**，由提示词、工具 schema、推理和输出共用。默认输出预算为 4096，公布的输出预算为 8192。日常使用时，输入不超过 **253952 token**，为输出保留 8192。这些是客户端预算，并非独立的硬性输出上限；调度器还会保留少量边界位置。最多同时运行四次生成，共用 270336 token 的常驻 KV 池；更多请求或容量受限的请求会排队。这不等于四个同时运行的完整 256K 上下文。
- 模型请求和流超时均为 2400 秒，自动模型重试已禁用。客户端还须设置匹配的 HTTP 空闲超时。一次接近 256K 的冷输入在首段文本出现前耗时 25 分钟；流式传输无法消除该等待。长时间冷预填充和请求队列仍可能超过此期限。四个约 60K 输入加各 4K 输出在算术上可放入池中；这只是规划预算，并非已完成的 4×60K 资格验证。
- HTTP 端点通过加密的 Tailscale 传输，仍要求 LiteLLM 身份验证。它使用现有 LiteLLM 实例和模型数据库。
- 现有 `https://models.beaco.works/v1` 仍可用，但在 2026-09-13，Cloudflare 拒绝了 Python/SDK user agent（403/1010），而 curl 可用。在修正公网 API 路径的浏览器检查前，优先使用 Tailnet 端点。

## Pi 客户端设置

针对 Pi 0.85.1，将以下内容合并到 `~/.pi/agent/settings.json` 或项目的 `.pi/settings.json`（项目设置覆盖全局设置）：

```json
{
  "httpIdleTimeoutMs": 2400000,
  "retry": {
    "enabled": false,
    "provider": {
      "timeoutMs": 2400000,
      "maxRetries": 0
    }
  }
}
```

`httpIdleTimeoutMs` 位于顶层，控制 undici 的 headers/body 空闲期限；仅修改 provider 超时仍会留下默认的 300000 ms 空闲上限。将 provider `baseUrl` 设为上述 Tailnet URL，模型 ID 设为 `thor/qwen3.8-27b`，`contextWindow` 设为 262144，`maxTokens` 设为 8192。普通对话轮次请求 4096 输出 token；推理也消耗同一输出预算。编码任务应保留模型正常的 thinking 行为。先前的容量探测只为隔离检索而关闭 thinking。不要通过公网 Cloudflare 端点发送这些长请求：它的期限独立于 LiteLLM 和 Pi 设置。

LiteLLM 1.90.0 优先使用模型 `stream_timeout`，其次才是 `timeout`，并遵守 `num_retries: 0`。共享网关启用了 `general_settings.cancel_on_disconnect: true`；它适用于所有模型路由，会在等待上游初始响应期间客户端断开时取消工作。客户端取消已沿链路测试到 Thor。此设置声明于公共 infra 的 `wanxiang/kubernetes/apps/ai/litellm/app/configmap.yaml`；修改这项通过 subPath 挂载的配置后需重启 Deployment。Thor 还回移植了 SGLang 生命周期修复，使已派发请求在客户端消失后中止，而非继续运行；参见 [Thor SGLang 客户端断开中止修复](thor-sglang-abort-fix.md)。

## 归属与部署

`hosts/personal/fixed/thor/inference.nix` 声明主机服务。其 `inference/` 目录包含最小补丁，以及源文件和结果文件的 SHA256 校验值。启动时从锁定的本地 Docker 镜像提取原文件并验证两类哈希。模型快照和镜像须预先存在于 `/var/lib/thor-inference`；重建 Nix 不会下载这些大型前置资源。镜像按本地 image ID 锁定，而非仓库 digest；清理 Docker 镜像时须保留它。

`terraform/litellm-wanxiang/` 管理模型记录、`ai/thor-inference` 出站 Service 和 `ai/litellm-tailscale` 入站 Service。现有 Tailscale Operator 管理其代理 Pod。显式 `tag:talos-ii-operator` 与正常运行的机群 Service 一致；Operator 默认 `tag:talos-ii-svc` 被其 OAuth 权限拒绝。不要覆盖 Operator 生成的 `externalName`。

流量路径：agent → LiteLLM → `thor-inference.ai.svc.cluster.local:8889` → Tailscale → Thor `100.88.133.23:8889` → 回环 SGLang `127.0.0.1:8888`。原始推理只能通过 Tailnet 监听器访问；模型服务器没有单独的 API 密钥。因此 Tailnet ACL 仍属于后端访问边界。

用 `KUBECONFIG=<cluster-config> terraform/litellm-wanxiang/run.sh plan` 和 `apply` 应用模型/网络变更，需备有 `kubectl` 和 `tofu`。脚本获取管理凭据但不打印它。Terraform 状态保存在现有 Kubernetes 后端。

管理 URL 是临时 Terraform 变量，因为每次调用可能使用不同的本地端口转发端口。因此保存的 plan 可以在新的转发会话中应用。

同一 stack 管理 `astrbot` 虚拟密钥。其 `ephemeral_body` 除密钥值外还带有 `_terraform_body_revision`：LiteLLM 在 `/key/update` 中以密钥值本身定位虚拟密钥，而 provider v0.25.2 只有在 ephemeral 值本身变化时才把 `ephemeral_body` 合并进更新请求。仅由 `body` 驱动的更新因此会缺少必需的 `key` 字段，LiteLLM 会返回 HTTP 422（`body.key: Field required`）。revision 是受管理 body 的哈希，因此任何 body 变动都会再次触发合并补丁；LiteLLM 忽略额外字段。只有 provider 在每次写入时都会合并 `ephemeral_body` 后，才能移除此 revision。

## 恢复

- `systemctl status thor-inference thor-inference-memwatch thor-inference-proxy.socket thor-inference-healthcheck.timer`
- `journalctl -u thor-inference -u thor-inference-memwatch -u thor-inference-healthcheck`
- 在 Thor 上运行 `curl --fail http://127.0.0.1:8888/health_generate` 检查生成健康状况。
- 进程意外退出后等待 30 秒重启；每 15 分钟最多启动三次。手动停止后保持停止。
- 独立定时器在 180 秒宽限期后检查生成健康；连续三次失败触发重启。执行操作前会检查服务 invocation，避免过期探测复活手动停止的服务。
- 内存保护每秒采样。Available 连续五次低于 12 GiB，或 Available 低于 18 GiB 且 Free 低于 3 GiB 时，停止推理并创建 `/run/thor-inference/memory-stop`。这是有意防止重启循环。
- 排除内存压力后，移除该锁并运行 `systemctl reset-failed thor-inference; systemctl start thor-inference`。重启看门狗不会清除锁。重启机器会清空 `/run`，但启动时内存门槛仍生效。
- 已停止的实验容器 `thor-27b-dflash16` 保留用于回滚。启动前先停止受管理服务，并恢复它原先的看门狗；两个容器绑定相同的回环端口。

服务保留 INT8 draft head、未量化的目标 BF16 head 和 DFlash block16。保留的 GDN 补丁仅适用于 block8，在 block16 下不生效（使用 BV32）。OpenAI 工具解析使用 `qwen3_coder`，与 checkpoint 的 XML 工具模板一致；推理解析仍使用 `qwen3`。

Operator 出站设计遵循 [Tailscale 文档](https://tailscale.com/docs/kubernetes-operator/egress)。Cloudflare 将 [1010 解释为浏览器签名检查](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/)；这与 LiteLLM 密钥授权不同。

## 验证——2026-09-13

在隔离 checkout 中构建了准确的私有 Thor 系统，排除了并行进行的网络改动。`nix flake show --all-systems`、`nix build .#nixosConfigurations.thor.config.system.build.toplevel`、shell 语法/ShellCheck、补丁重放 SHA256 检查和独立审查均通过。dry activation 只显示预期的防火墙重载；服务切换成功。已验证开机启用；未重启机器。

通过 Tailnet LiteLLM 端点和现有 agent 密钥：

| 检查 | 结果 |
| --- | --- |
| 模型列表端点 | HTTP 200；前述旧版通配列表 |
| 缺少 API 密钥 | HTTP 401 |
| 聊天补全 | 返回预期文本，HTTP 200 |
| SSE 聊天补全 | 拼接后为预期文本，HTTP 200 |
| JSON 对象输出 | 解析出预期状态和值 |
| 工具调用 | 函数和整型参数正确 |
| 工具结果续接 | 最终回答正确 |
| SSE 工具调用 | 重新拼接得到有效函数名和参数 JSON |
| 容器意外退出 | systemd 将其重启一次；生成健康检查及后续 LiteLLM 请求均通过 |

恢复和最终模型元数据更新后，最后八项 API 检查再次通过。`supports_function_calling=true` 基于这些检查。Terraform 的 `fmt -check`、`validate` 和完整 `plan -detailed-exitcode` 均通过；plan 报告无变更。由于 LiteLLM 在读取时掩码后端的 dummy API key，provider 将其视为只写。

原始本地证据保存在 Git 之外的 `/home/beacon/.cache/codex/thor-api/`（`smoke-results.json`、`recovery-result.json`、构建和 Terraform 日志）。没有创建新的客户端密钥。这是单台 Thor 后端；重新加载模型会暂时中断服务，基础设施冗余仍待后续完成。

## 事件——2026-09-14：启动旧代后离线

Thor 可通过保留的 LAN 地址访问（有线 `172.16.20.71`，无线 `.81`），但 Tailscale 报告其离线约四小时，LiteLLM 请求超时。旧 DHCP 地址 `.201` 和 `.237` 不再响应。

`/run/booted-system` 与 `/run/current-system` 指向第 6 代，既无 `tailscaled.service`，也无 `thor-inference.service`。系统 profile 仍指向已部署的第 8 代。`/boot/loader/loader.conf` 正确选择第 8 代，但 EFI `LoaderEntryDefault` 变量明确选择 `nixos-generation-6.conf`，覆盖了文件。现有证据无法确定最初是谁或什么设置了该 EFI 覆盖项。

恢复：`bootctl set-default ""` 清除了持久 EFI 覆盖项，使声明式 loader 默认值生效；`/nix/var/nix/profiles/system/bin/switch-to-configuration switch` 恢复了现有第 8 代服务。随后 `bootctl list` 将第 8 代标记为默认。Tailscale 使用相同的 `100.88.133.23` 身份和直连 LAN 端点重新连接。无需重置身份验证或重新注册 Tailscale。未再次重启；通过 bootctl 验证引导选择，而服务在原地恢复。

检查重启持久性时，同时核对系统 profile 和 `bootctl status`/`bootctl list`；当前激活系统中的 unit 已启用，不代表固件下次会选择这一代。证据位于 `/home/beacon/.cache/codex/thor-api/20260914/`。

恢复后八项 Tailnet API 检查全部通过（此次简短冒烟测试中，chat 0.38 秒、SSE chat 0.34 秒，JSON 和工具流程均不到一秒）。使用 curl user agent 的公网端点重试返回 HTTP 200，1.32 秒获得完整 SSE `OK` 输出；这不能证明兼容所有 SDK user agent。第一次公网探测出现客户端 JSON 解析失败，原始证据已保留。结束时 tailscaled、推理服务及内存/健康监控均在运行。缺少实际模型/请求细节，无法断定所报告的 pi 524 与此次事件有关。

这次仅更新文档，运行了 `git diff --check`。尝试了广泛 flake 求值，但从 Forgejo 获取锁定的公共 infra 仓库受阻；恢复期间未更改 Nix 配置。

## 延后扩展上下文——2026-09-14

只读容量评估，以及厂商技术负责人的 [768K YaRN 报告](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-yarn-768k/) 和 [900K 报告](https://manateelazycat.github.io/2026/08/28/qwen-3-8-27b-900k-context/)，记录在公共 infra 仓库的 [模型文档](model/qwen3.8-27b/original.md) 中，包括报告数值、缺失的复现设置和延后的测试清单。

锁定的 target/draft 均原生支持 262144 个位置。按此规模计算，BF16 KV 为 21 GiB；当前主机可用内存约 82 GiB。候选验证使用 context262144/pool270336，并保留现有保护。这些只是估算，尚未完成长上下文测试。证据保存在 `/home/beacon/.cache/codex/thor-api/context-capacity/`。更改本服务、LiteLLM 元数据或 agent 预算前，须先验证原生容量，再验证所报告的 YaRN 范围。当时部署仍为 4K。

技术负责人的 [2026-08-27 并发报告](https://manateelazycat.github.io/2026/08/27/qwen-3-8-27b-125-tokens/)（预填充 3754 TPS、长代码解码 125 TPS、八会话代码解码 231 TPS、70 GB 内存）也保存在该处。它不能证明八个同时运行的 256K/900K 请求。当时 `max-running-requests=1` 是明确的服务设置；超出该数的请求排队。

## 原生 256K 试验——2026-09-14

临时 context262144/pool270336 试验在 32769、131072 和 261120 输入 token，以及相同前缀复用场景下完成了原生检索。全部正确返回三个事实并正常完成。首段文本延迟分别为 31.367、397.149、1506.754 和 11.613 秒；复用命中 260096 个缓存 token。采样到的主机 Available 最低为 60.70 GiB，推理自动重启为零。完整参数、输出计数和限制详见公共模型文档。

随后通过 Tailnet LiteLLM 端点发送热缓存的 261120 输入 archive 请求，返回 HTTP 200 和全部事实；首段文本 3.237 秒，完成 9.394 秒。这证明热缓存 API 路径可用，不能证明冷长请求可用：当时的 300 秒超时短于测得的冷 128K/256K 预填充。公网入口和客户端期限也需验证。

试验从隔离 checkout 使用 `switch-to-configuration test`；保留第 8 代 boot profile，随后将运行时恢复至该代。当时生产配置仍为 4K、默认输出 1024、单个运行请求。未修改 LiteLLM 元数据或永久 Nix 参数。只有同时处理超时、客户端预算及增量/缓存淘汰测试，才能提升容量；长时间冷预填充当时会阻塞队列中其他 agent。证据：`/home/beacon/.cache/codex/thor-api/context-capacity/evidence/`。

恢复成功；运行时再次与第 8 代一致。之后八项 Tailnet 冒烟检查全部通过（chat、SSE、JSON、工具/续接/流、模型列表及未认证拒绝）。两个仓库的 `nix flake show --all-systems` 和 diff 检查均通过；由于 Forgejo HTTPS 获取不可用，私有仓库求值通过本地 Git 使用相同的锁定公共 infra 修订。隔离试验的准确 Thor 系统也在激活前成功构建。

## 长请求服务资格验证——2026-09-14

第二次试验使用兼容 OpenAI 的 Tailnet 端点，而非直接原生生成。LiteLLM 1.90.0 的模型 timeout 和 stream timeout 提高到 2400 秒，模型重试禁用。131072 token 冷请求返回 HTTP 200、全部三个 archive 事实、50 输出 token；首段文本 398.648 秒，完成 401.928 秒。十秒后提交的短请求在 392.852 秒后正确返回，说明是队首阻塞而非并行执行。

追加实际 assistant 回复和后续问题后，得到 131149 输入 token；首段文本 2.225 秒，完成 4.890 秒。后端日志确认 131072 个缓存 token 和 77 个新 token。检索仍正确。此次测试中的网关 usage 未包含缓存 token 细节；应使用后端证据，不要假设这些 usage 字段对外暴露。

另一个 128K 请求在首段文本前的 15.027 秒断开。五秒后短请求在 0.364 秒内完成。这验证共享网关启用断开取消后会释放槽位，但并非对所有外部 provider 的完整取消测试。

证据及探测脚本保存在本地 `/home/beacon/.cache/codex/thor-api/context-service/`。

32769 token archive 在显式清空缓存前后都正确返回（首段文本 32.070/31.698 秒，完成 33.572/33.203 秒）。第一次 32K 请求虽然 fixture 标注为 `warm-32k`，也未命中缓存。这测试的是刻意丢失缓存，而非多 agent 下的自然淘汰。超限的 263169 token 请求在 1.786 秒内返回 HTTP 400。

检查结束后，context262144/pool270336 永久提升，LiteLLM 元数据/默认输出同步更新。文首操作说明取代先前临时试验的恢复说明。客户端公布的输出预算为 8192；这些简短检索输出未验证在上下文上限处生成 8192 token 的质量。

持久提升完成至第 9 代，系统路径 `/nix/store/0fn7i9jw4jvf3vzdvaz80kmmhzx4kr2w-nixos-system-thor-26.05.20260910.d58a46e`。运行时和系统 profile 一致，`bootctl list` 默认选择第 9 代；未再次重启。部署 closure 是先前已验证的隔离 Thor 配置加两个上下文参数，排除了同期无关仓库改动。

最终八项 API 冒烟检查通过。推理及内存/健康监控保持运行，本次试验中自动重启为零。Terraform 最终完整 plan 报告无变更。两个 flake 求值通过，准确的隔离 Thor closure 构建成功，ConfigMap 服务器端 dry-run 和 rollout 通过，仓库 diff 通过空白检查。私有仓库求值再次通过本地 Git 使用相同的锁定公共修订。上述 Pi 设置已对照安装的源码验证，是移交说明；另行维护的 Pi extension 未在此编辑或部署。
## 四个活跃请求与按需实验——2026-09-14

生产环境现设 `max-running-requests=4`、`max-mamba-cache-size=24` 和 `cuda-graph-max-bs-decode=4`。采用此 overlap/extra-buffer 配置时，运行时每个请求需要五个 Mamba 槽位；若只修改请求上限，旧的八槽设置仍会将并发限制为一个。context262144、共享 pool270336、block16 和现有内存保护保持不变。

初步验证观察到四个同时运行的 CUDA graph 解码请求。一个、两个和四个短代码请求均返回 384 输出 token，且无 API 错误；该上限可能截断代码，因此这只是并发检查，不是代码正确性或隔离性能基准。四份独立的约 32K archive 均正确返回各自案例的三个事实。首段文本耗时 32.520–129.091 秒，四个请求均在 130.601 秒内完成。即使有四个槽位，预填充调度仍影响延迟。八路服务及四个完整 256K 输入尚未验证。

`thor-inference-experiment.service` 已安装，但未设置开机启用。它启动锁定模型/draft 的另一个实例，使用 4096 上下文、8192 KV 槽位、一个运行请求、八个 Mamba 槽位和 graph batch 1。仅绑定 `127.0.0.1:8890`，后端模型名为 `qwen3.8-27b-thor`。它没有注册为普通 LiteLLM 路由。调查 agent 继续使用生产 LiteLLM 模型，通过 SSH 控制和探测实验。

在 Thor 上：

```sh
sudo systemctl start thor-inference-experiment
curl --fail http://127.0.0.1:8890/health_generate
sudo journalctl -u thor-inference-experiment -n 50
sudo systemctl stop thor-inference-experiment
```

实验共用只读模型快照，但使用自己的 `/var/lib/thor-inference/experiment/{kernel-cache,work,runtime-patches}`。启动时会准备锁定补丁的新副本；手工修改这些生成副本不能持久定义候选配置。未来候选补丁应纳入版本管理，且只接入实验启动配置，保持生产补丁输入不变。启动基线实验不会自动进行优化。

准入要求主机 `MemAvailable` 达 48 GiB。运行期间，其独立看门狗会在 Available 低于 18 GiB，或 Free 低于 4 GiB 且 Available 低于 22 GiB 时立即终止实验容器。生产环境保留 12/18 GiB 保护。启动失败也会强制移除实验容器。它不会自动重启，且一小时运行上限约束遗忘的实验。Docker 的 48 GiB 内存设置不是 GPU 分区；统一内存环境仍需主机内存看门狗。

共存仅是功能测试。性能比较前须先准备所有候选/参照命令及检查；独立的限时编排任务必须停止生产服务和其他 GPU 工作负载，单独运行各变体，并在成功或失败后恢复生产。模型自己的生产服务器停止期间无法再发起推理调用，但已派发的 shell/systemd 任务可继续执行，并在 agent 下一轮前恢复服务。不要将共存时的耗时解释为隔离吞吐量结果。

完整的第二个 DFlash 实例**未**通过共存资格验证：CST 15:39:17，采样 Available 降至 21.746 GiB、Free 降至 0.988 GiB，触发实验的低 Free/Available 保护。实验被终止并移除；生产保持运行，自动重启为零。这证实保护及启动失败清理路径有效，不能证明双实例推理成功。没有进行性能比较。实验仍停止且未开机启用。提议的 target-only 后备方案未部署或测试，不包含在此次变更中。按用户要求，后续实验暂停。

持久配置使用当时已在运行的四请求 closure `/nix/store/cvcc17f3dggib69hdf2znkf3ifwbr3la-nixos-system-thor-26.05.20260910.d58a46e`。最终移交仅更新系统 profile 和启动配置；生产服务未重启。LiteLLM 描述现已明确说明四个活跃请求共用 270336 个常驻 token。上文单请求及临时试验描述属于历史状态。

最终移交将第 10 代设为默认启动项。仅更新启动配置前后的生产 InvocationID 相同，确认服务未重启。准确 closure 重新构建至相同 store 路径，广泛 flake 求值及 shell 语法检查通过，LiteLLM 元数据应用仅修改本模型描述。排除了无关的 agent 编辑。

## NInfer 后续测试与恢复——2026-09-14

Pi 会话在一次工具调用中停止了 `thor-inference`，接下来的模型调用却返回 HTTP 500。检查时已无 NInfer 进程运行，只剩构建容器中的空闲 `sleep`；在继续用户授权的调查前先恢复了生产服务。

现有 `/home/beacon/ninfer-port` 源码和 `/home/beacon/ninfer-artifacts/qwen3_8_27b.ninfer` 产物在 Thor 上运行成功。该产物是 groupwise-int，而非 NVFP4。生产服务停止期间，跨 eager、Graph 和 DFlash2 的九项简短功能检查，以及四项相关设备测试均通过。公共模型文档记录了准确范围、内存数值和剩余的 NVFP4 stub 限制。

测试编排采用带 `ExecStopPost` 的限时 systemd 任务，在失败或超时情况下也停止 `ninfer-build` 容器并启动 `thor-inference`。因此已派发的工具任务不需新模型轮次即可恢复推理。若 agent 依赖被停止的服务，不要把停止/测试/恢复拆成不同 agent 轮次。NInfer 构建容器仍可用，但会被清理逻辑停止；源码、产物和结果的 bind mount 保留。

证据：本地 `/home/beacon/.cache/codex/thor-api/ninfer-followup/`，Thor 上 `/home/beacon/ninfer-port/thor-followup/`。生产配置和 LiteLLM 模型路由未替换为 NInfer。

首次无 draft 共存尝试虽然主机 Available 为 56.65 GiB，仍未通过 CUDA-free 准入。NInfer 现使用以 Linux MemAvailable 为依据的核心集成 GPU 预算查询，并有 CUDA 后备，但不计入 SwapFree。公共模型文档归档了补丁、来源和测试范围。

重建时发现现有构建容器缺少 FFmpeg 开发文件。匹配的 Ubuntu arm64 6.1.1-3ubuntu5 开发包被解压到 `thor-followup/dev-overlay`，未安装系统包；CMake 使用这些头文件和现有带版本号的运行库。证据目录中的 `ninfer-build-memory-fix.sh`、`dev-packages.sha256`、构建日志及 CPU 测试日志保留准确恢复步骤。CLI 重建成功，`ninfer_memory_test` 通过。

修正后的 CLI 在生产服务常驻时通过 `postfix-coexist/` 的全部九个案例。173 次间隔半秒的采样中，Available 最低 35.71 GiB，Free 最低 8.20 GiB。这是分别采样得到的两个最低值，不是最大负载资格验证。生产 InvocationID 未变，NRestarts=0；运行期间两项简短 LiteLLM 检查返回预期输出（HTTP 200），最终清理后检查耗时 0.318 秒并通过。实验容器已停止，生产服务运行，四请求/256K 配置未变。不要从这次短试验推断四个长请求的容量余量。

### NInfer 服务试验

修正后的 `ninfer-serve` 重新链接后，以 32K 上下文、64K 共享 Main KV、四个活跃请求、FP8 KV 和 DFlash2 进行测试。Host KV 明确设为 1 GiB，带四个 Host state 槽位；临时 thinking 预算为 128 token。监听器仅位于容器回环地址，从未加入 LiteLLM。全部十二项生成探测通过，覆盖 SSE、工具往返、真正的四行解码、thinking，以及 27,916 token 检索后续接缓存。准确结果和限制详见公共模型文档。

证据位于 Thor 上的 `/home/beacon/ninfer-port/thor-serving/` 和本地 `/home/beacon/.cache/codex/thor-api/ninfer-serving/`。`command.json` 包含准确启动参数，`probe.py` 包含 fixture，`results.json` 包含响应，`requests.jsonl` 包含 Engine 计数器。限时 `thor-ninfer-serving` 任务沿用独立清理逻辑，另设 Available 低于 20 GiB 时停止实验的阈值；采样 Available 最低为 30.92 GiB。清理成功，构建容器已停止，生产服务保持运行且未重启。

### 独占 NInfer 对比与 NVFP4 移植

用户明确授权本次试验独占 GPU。`thor-ninfer-benchmark-full` 任务测量常驻 SGLang 基线，然后停止它，再测量 NInfer groupwise plain/draft7。随后的 `thor-ninfer-nvfp4-fixed` 任务测量修正后的 NVFP4 A16 路线。`ExecStopPost` 在每种退出情形（包括失败）下停止 `ninfer-build` 并恢复 `thor-inference`。使用该后端的 Pi agent 应在一个工具调用中派发整个测试/恢复任务，等待清理完成后再请求下一轮模型响应；`systemd-run --wait` 适合此用途。

第一次 SwiGLU 边界 oracle 暴露出通用 32-token 上限被用于仅支持 2–16 的 launcher 表；修正后的 SwiGLU 专用共用上限及带检查的表查找通过全部现有和新增边界案例。五项 NVFP4/FP8 设备测试及九项真实 NVFP4 功能案例通过。公共文档归档了可从原始 tar 重放的完整补丁，包括先前的 Pi 和内存更改。

作者的匹配 NVFP4 产物现位于 `/home/beacon/ninfer-artifacts/qwen3_8_27b_nvfp4.ninfer`；下载已锁定并经 SHA256 验证。这是带 FP8 输出 head 的混合方案，不是生产环境的 ModelOpt/BF16-head checkpoint。源码、限时 launcher 和原始证据位于 `ninfer-port/thor-benchmark/`、`ninfer-port/thor-nvfp4/` 和 `/var/lib/thor-inference/work/ninfer-benchmark/`；本地副本位于 `/home/beacon/.cache/codex/thor-api/ninfer-benchmark/`。初次失败的 oracle 日志单独保留。生产配置和 LiteLLM 路由均未更改。

最终清理成功：`thor-ninfer-nvfp4-fixed` 为 inactive、Result=success，`ninfer-build` 已停止，`thor-inference` 运行且 NRestarts=0。最终 LiteLLM 短请求在 0.463 秒内返回 HTTP 200 和预期输出。NVFP4 draft7 代码解码达到 25.51 tok/s；groupwise draft7 为 22.79，SGLang 为 66.47。NVFP4 draft15 在计数任务上达到 46.60 tok/s，但四请求合计仅 53.37 tok/s；1843-token 预填充 TTFT 仍约 25 秒。这些实测后备结果不足以支持替换日常 SGLang 服务。下一步原生 kernel 入口点及完整对比记录在公共文档中。

### 原生 SM110 MLP down 资格验证

独占 `thor-ninfer-native-probe` 任务验证了 `[5120,17408]` 上的 CUTLASS 原生 NVFP4 GEMM；后续又将 BF16 activation 量化和 residual 加法整合进调用方拥有的 LinearAdd Op。只有 27B MLP down 策略及匹配的 workspace 规划选用此路线，在 T>=8 时使用 `AllowA4`。通过 `-DNINFER_CUTLASS_INCLUDE_DIR=/opt/sglang/lib/python3.12/site-packages/flashinfer/data/cutlass/include` 启用实验构建。它使用已安装 FlashInfer 0.6.17 附带的 CUTLASS 头文件，但没有 FlashInfer Python 运行时依赖。生产配置未改变。

打包探测通过十种形状。完整 LinearAdd 通过独立 FP64 标准、workspace 保护和输入变化的 Graph replay；全部九个模型案例通过。首个测试 fixture 为 A16 路线错误借用了零字节，成功运行前已修复。完整 Op 在 T16 时延迟 0.284 ms，在 T1024 时为 0.750 ms。DFlash2 draft7 的模型代码解码从 25.51 提升至 28.43 tok/s（+11.4%）；无 draft 的 1843-token TTFT 从 25.00 降至 17.84 秒（-28.6%）。无 draft 代码解码仍为 10.46 tok/s。这些结果仍低于之前的 SGLang 基线。

第一次补充四请求 fixture 的三个响应返回了错误 JSON key，导致 `thor-ninfer-native-model-fixed` 退出并恢复生产。随后限时 `thor-ninfer-native-batch` 任务测试了四个更长、明确的 JSON 对象：四个均恰好返回 95 token，引擎日志确认四个正在运行、可解码的行，batch size 为 4。这属于执行资格验证，不构成广泛的质量或吞吐量结论。失败 fixture 和原始输出保留在证据目录。

所有任务使用独立 `ExecStopPost` 清理。最终 batch 任务为 inactive、Result=success；`ninfer-build` 已停止；`thor-inference` 运行且 NRestarts=0。最终 LiteLLM 请求在 0.414 秒内返回 HTTP 200 和预期 `OK`。主四请求、256K 服务仍为常规路由。远端证据为 `/home/beacon/ninfer-port/thor-native/`；本地证据为 `/home/beacon/.cache/codex/thor-api/ninfer-native/`。公共模型文档归档了测量结果、独立探测程序及针对原始 tar 重放的完整源码补丁。后续原生工作可从 MLP gate/up 着手；本次试验未实现它。

### 活跃 Pi 长上下文变慢——2026-09-15

北京时间约 03:30 的被动调查，在 `~/.pi/agent/sessions/--home-beacon-infra-private--/` 找到本地 Pi 会话 `2026-09-14T15-33-22-132Z_01a0a08d-2e53-72ba-a3ae-9ce9950b2bb5.jsonl`。03:26 的快照中有 70 条 assistant 消息、92 条工具结果，且未进行压缩；报告的输入从 6680 增长至 140671 token。报告的累计输出约 85009 token，其中推理 token 约 65766（77%）。一条早期上游 usage 记录不一致，因此这些合计值为近似值。未修改或中断会话内容、配置或活动进程。

Pi 0.85.1 将此模型注册为 contextWindow=262144/maxTokens=8192。其生效的默认压缩设置为启用、reserveTokens=16384、keepRecentTokens=20000，仅在上下文超过约 245760 token 时触发。`openai-completions.js:1000–1006` 将此会话的思考块重放为 `reasoning_content`；已部署模型的 `chat_template.jinja:111–117` 默认包含它们。即使设置 preserve_thinking=false，最后一条用户查询之后的思考仍会保留，因此这不是长期自主工具序列的可靠补救措施。任意删除进行中的推理，不能代替经验证的语义压缩。

四小时生产日志显示单请求解码采样，没有排队请求。以下分组中位数来自真实任务的不同阶段，是观察值，不是固定提示词的受控基准：

| 完整 token 数 | 样本数 | 日志中的生成 tok/s | 接受长度 |
|---|---:|---:|---:|
| 32768–65535 | 97 | 9.75 | 3.40 |
| 65536–99999 | 175 | 7.49 | 3.38 |
| 100000–124999 | 112 | 6.79 | 4.10 |
| 125000–149999 | 68 | 4.63 | 3.33 |

当时只有生产容器运行；NRestarts=0，MemAvailable 约 56 GiB，内存 PSI 平均值为零。简短的被动 tegrastats 采样显示 GPU 接近 50 C、时钟 1385 MHz、EMC 在 4266 MHz 下利用率为 18–20%。这不能证明存在饱和或温度限制。先前短提示词测得的 66.47 tok/s 不能代表此次 140K 上下文的推理负载。256K 容量验证并未证明在该占用量下日常延迟可接受。

已安装源码指出一个很强的性能假设，但尚未经 profiling 确认归因。`triton_backend.py:196` 中 split-KV target verify 仅限 gfx95/ROCm。Thor 的 verify 改而调用 `extend_attention_fwd`（:1417–1462）。`extend_attention.py:462` 在每个 query tile 内扫描完整前缀；其 grid（:837）没有前缀拆分维度。对于 hd256，选中的 tile 是 M64/N64，而 DFLASH 只验证 16 个 query token。`dflash_worker_v2.py:1905–1952` 的 draft attention 也使用完整前缀，随后执行 target verify（:2005–2052）。每轮不会重新计算历史 K/V：只追加当前 hidden block（:2187–2201）。但 attention 每轮仍重新读取长前缀。普通 decode 的 num-kv-splits 参数不能处理这条 verify 路径。

全模型 FA4 仍受阻：已安装 CuTe 接口在 SM100 与 SM110 上均选择专用 hd256 kernel（:900），却拒绝 `seqused_q`／`seqused_k`（:1458）。SGLang 的 FA4 KV wrapper 提供 `seqused_k=cache_seqlens`（:276–283）。仅支持底层 SM110 并不能消除这一接口限制。FP8 FA4 另有独立的 SM100 架构保护；两项改动都尚不能用于生产。

下一个空闲窗口的优先事项：

1. 独立于后端保留的 256K 容量，验证 Pi 将语义压缩目标设在约 32–64K 的方案。研究模型专用软阈值；不要虚构 Pi 设置或全局改变其他模型。常规清单工作可另行比较减少推理量，并在有益的决策中保留 medium。两种变更均未应用。
2. 在固定的 32K／64K／128K 提示词下比较 DFLASH16／8／4 和无 draft，保持 KV dtype 和 attention backend 不变。测量每轮时间、接受率、TTFT、生成速率和正确性，不要假定更短的 block 必然胜出。
3. 单独将 draft window 8192／32768 与完整上下文基线比较。已安装的 `--speculative-draft-window-size` 限制 draft，同时保持 target 上下文完整；必须检查接受率和检索。上游[服务端参数文档](https://sgl-project.github.io/advanced_features/server_arguments.html)也说明了此行为。
4. 部署前研究并验证 CUDA split-KV verify 实现，或修复 FA4 hd256 paged/varlen 接口。相对于此次生产长上下文问题，后续 NInfer gate/up 工作优先级较低。

原始生产日志位于本地 `~/.cache/codex/thor-api/production-slow/sglang.log`；只读的已安装 attention 源码快照位于 `/tmp/thor-installed-audit/`。此次调查未执行 API 负载、GPU profiling、编译、服务重启或实时 Pi 配置修改。

## 受控短提示词比较——2026-09-18

停止官方 AI Pod 上正在运行的请求后，对官方 vLLM 部署和早期 NixOS SGLang 部署运行相同的单请求基准。两者均采用流式传输、`max_tokens=512`、temperature 0 和 `enable_thinking=false`；没有并行运行其他请求。

| 案例 | 提示词 token | NixOS/SGLang | 官方 AI Pod/vLLM |
| --- | ---: | ---: | ---: |
| 依次列出整数 1–2000 | 43 | 119.4 tok/s | 114.4 tok/s |
| Python 异步 HTTP 队列模块 | 82 | 66.5 tok/s | 49.3 tok/s |

计数提示词原文为 `Output the integers from 1 to 2000 in order, separated by commas. Do not explain or stop before 2000.`。代码提示词要求完整的、仅用 Python 标准库实现的异步 HTTP 作业队列，包含重试、取消、期限、JSONL 持久化及六个 unittest 案例。这些是短合成解码基准，不是长上下文生产任务。比较结束后，官方部署处于空闲状态。
