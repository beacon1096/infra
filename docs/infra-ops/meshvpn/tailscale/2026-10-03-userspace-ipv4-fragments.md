# 2026-10-03：userspace 接收路径中的 IPv4 分片

本记录整理 SSH 停滞、尺寸边界探测和精确版本源码对照。前半部分保留首次调查的证据边界；10 月 3 日补做的接收侧版本 A/B/A 实验见“验证结论”。

## 症状与最初判断

默认 SSH 停在 `expecting SSH2_MSG_KEX_ECDH_REPLY`。这表示客户端正在等待回复，尾句本身不能证明 KEX request 已到达服务端，也不能定位请求、回复或中间转发中的丢失位置。

缩减 SSH 算法组合、设置 `TS_DEBUG_MTU=1200` 都曾缓解症状，提示应调查包长相关路径。但相关操作伴随重启，且缺少同期 direct/DERP 状态，因此存在混杂因素，不能据此单独认定因果或修复完成。

## 抽象路径与探测口径

仅用角色描述相关转发边界，不代表实际服务拓扑：

```text
客户端容器 → 中间子网路由节点（Linux tailscale0，MTU 1280）
           → 接收端（userspace FromPeer → netstack）
```

这里使用的是 `tailscale ping --size`，未带 `--tsmp`，因此是 disco 尺寸探测。以下按观测到的 UDP payload 长度，加上 8 字节 UDP 头与 20 字节无选项 IPv4 头计算，不将它等同于 SSH 应用数据长度或全部隧道开销。

| disco 尺寸 | 分片前 IPv4 总长 | 中间节点行为 | 接收端观察 |
| --- | --- | --- | --- |
| 1252 | 1252 + 8 + 20 = 1280 | 无需分片，探测成功 | 作为尺寸边界基线 |
| 1253 | 1281 | 两片总长分别为 1276、25 | 两片均到达 userspace `FromPeer` |
| 1400 | 1428 | 两片总长分别为 1276、172 | 两片均到达 userspace `FromPeer` |

表中分片长度均包含各自的 IPv4 头。首片承载 1256 字节 IP payload，满足非末片的 8 字节对齐要求，所以首片总长是 1276，而非恰好 1280。重组需去掉重复的 IP 头：例如 `1276 + 25 - 20 = 1281`。

两组分片重组后的校验和合法。这将调查从“分片是否在网络中丢失”推进到“接收端收到分片以后怎样处理”；到达 `FromPeer` 仍不等于送达 UDP socket。

## SSH 同期包观察

与 SSH 同期观察到四组 IPv4 分片，每组两片总长为 `1276 + 68`。重组后的 IPv4 总长为 `1276 + 68 - 20 = 1324`，减去 IPv4 与 UDP 头，UDP payload 为 1296 字节。

该 payload 的首个小端序 uint32 为 `4`，对应 WireGuard transport data 消息。它支持“大包涉及 WireGuard 数据路径”的判断，不直接揭示加密内容，也不能据此断言某个包就是 KEX request 或服务端回复。

## 精确版本源码对照

将观察到的真实包直接交给 **exact v1.98.5** 的 `gro.RXChecksumOffload`；再以 **v1.102.5 原样 `gro.go`** 做 overlay，并保持旧版本 pinned 依赖。`true` 在下表表示函数返回非 nil 包对象，不代表端到端通信成功，也不表示逐片验证了完整 UDP 校验和。

| 输入 | exact v1.98.5 | v1.102.5 gro.go overlay |
| --- | --- | --- |
| 合法重组完整包 | true | true |
| 首片 | nil（丢弃） | true |
| 尾片 | true | true |

另以校验和损坏的完整包作负对照，旧函数与 overlay 均将其丢弃。

旧接收路径在 IPv4 重组前尝试验证 TCP/UDP 的 L4 校验和，而该校验和覆盖完整的重组后传输层包。首片仍带真实 UDP 协议号，却只有部分 payload，因此会被错误丢弃。非首片由 `packet.Parsed.Decode` 标为 `ipproto.Fragment`，原本就绕过这段 L4 预校验；这解释了首片 nil、尾片非 nil 的不对称结果。

修复保留 IPv4 头校验，识别首片的 More Fragments 标志，跳过重组前的 L4 预校验，让分片进入 gVisor 重组路径。负对照说明对完整坏包的校验并未被一概关闭。

上游 [PR #20321](https://github.com/tailscale/tailscale/pull/20321) 修复 [#20320](https://github.com/tailscale/tailscale/issues/20320)，合并提交为 [`52fdadbf8b9ef5398db4ab9b69ffe1a328c260a6`](https://github.com/tailscale/tailscale/commit/52fdadbf8b9ef5398db4ab9b69ffe1a328c260a6)。修复首次进入稳定版 **v1.102.1**，**v1.102.5** 包含该修复。

上述 overlay 实验只是函数级源码对照，不是现场 daemon 升级，更不是部署验收。

## 两个层面的相关 edge case

[上游 #16375](https://github.com/tailscale/tailscale/issues/16375) 与 [#20668](https://github.com/tailscale/tailscale/issues/20668) 有助于解释 fake-direct 与嵌套路径为何触发包长、MTU 和分片问题。它们描述的是触发路径层；本记录定位的 userspace checksum 缺陷是收到分片后的处理层。

#20668 的复现主要在 kernel/TUN 路径，不能将其与 userspace 首片校验缺陷视为同一问题，也不能认为一个修复可以消除所有嵌套路径的 MTU 问题。

升级应覆盖实际执行 userspace 接收处理的组件，它不一定是发起 SSH 的客户端；嵌入 Tailscale 的组件也应核对其实际库版本。现有证据不要求为此放弃 userspace/sing-box 单 TUN 架构。单机实验与正式声明配置的发布验收应分别记录。

## 验证结论

2026-10-03 04:13–04:22 UTC，完成接收侧 **1.98.5 → 1.102.1 → 1.98.5** 对照。
客户端容器始终运行 1.98.5，没有重建容器或重启其 daemon；两端均保持默认 MTU，
SSH 不缩减算法、不使用已有 multiplex 连接。

| 阶段 | 接收侧 daemon | 默认 SSH 独立连接 | 尺寸探测与其它验收 |
| --- | --- | --- | --- |
| A：重启旧版控制 | 1.98.5 | 0/3，均超时 | 1252 可走私网 direct；大尺寸未取得该私网路径的 pong |
| B：仅换接收侧二进制 | 1.102.1 | 3/3 成功 | 1252/1253/1400 均走原私网 direct；全 15 项巡检通过；4 MiB 传输成功 |
| A：切回旧版 | 1.98.5 | 0/3，均超时 | 小尺寸重新选中原私网 endpoint 后，默认 SSH 再次失败 |

新版额外 SSH 日志确认使用 `mlkem768x25519-sha256`、收到 KEX reply 并完成认证；
4 MiB 传输实际收到 **4,194,304 字节**，退出码 0。
中间节点同步抓包仍看到 1253、1400 和 SSH/WireGuard 的 IPv4 分片，
因此新版成功并不是通过消除嵌套路径或改走 DERP 得到的。

回旧版后，大尺寸 disco 曾经由另一个公网 endpoint 成功，但默认 SSH 仍选用私网
endpoint 并超时。它说明验收必须看具体 endpoint，不能仅以 `tailscale ping` 退出码
或“某条 direct 成功”判定原路径修好。

实验使用校验 SHA-256 的官方 1.102.1 amd64 静态包，以临时 runtime `ExecStart`
覆盖运行接收端 daemon；保留原 state、socket、端口、userspace 与代理参数，
期间暂停 Comin。节点身份、地址和子网宣告未变。实验后移除覆盖、取消回滚定时器，
恢复旧 daemon 与 Comin，系统 generation 未变。这是单机可逆验收，不是正式发布。

**在本次已确认的路径上，仅升级 userspace 接收侧至 1.102.1 已足够恢复默认 SSH，
无需先升级客户端容器。** 版本对照使用官方静态新版与原 Nix 构建旧版，
不是只改一行代码的现场实验；它与此前真实分片的函数级对照共同支持 #20321 的解释。
嵌套选路、额外封装及其它拓扑的性能问题仍独立于首片校验修复。

## 验收清单

- [x] 核对实际 userspace 接收者的运行版本及修复覆盖，记录现场 daemon 升级状态。
- [x] 默认 MTU 下执行 disco 尺寸 1252、1253、1400 的同口径探测。
- [x] 使用默认算法配置、含 MLKEM 的 SSH 完成连接与传输验证。
- [x] 完成相关访问路径和服务的全 15 项巡检。
- [x] 同期记录 direct/DERP 状态、重启情况及路径变化，增加旧版重启控制与回切复现。
- [x] 复核新版测试时中间节点仍产生分片，结合原接收端真实包及函数对照核对机制。
- [ ] 将接收侧版本修复纳入声明配置并完成正式发布后的验收。

## 统一包版本与发布边界

统一版本的声明改动采用 `lib/tailscale-overlay.nix`，由 flake 导出
`overlays.tailscale`。以实测通过的 1.102.1 为基线，固定源码与 vendor hash，
使用公共 nixpkgs 的 Go 工具链，保留 Linux/Darwin 包装及 `derper` 输出。
主机配置和直接导入 pkgs 的 Coder/edge 镜像都需要消费这个 overlay，
不能仅修改某一台机器的 `services.tailscale.package`。

源码构建及 x86_64-linux 二进制版本检查已通过；ARM/Darwin 已完成定向求值。
这不等于 fleet 已发布。扩展仓应先消费合入后的公开实现，再更新锁定的公开输入；
本地 path override 只用于跨仓求值，不能作为生产 lock。

还需区分三个边界：

- 保留 MeshVPN 的可选 MTU 表达，但默认 `null`，不把 1200 变为统一默认。
- 系统 `pkgs.tailscale` 升级不会自动更新独立容器镜像。本轮后续声明改动
  已移除 sing-box 内置后端，并采用外置 SOCKS provider；Darwin 需要单独完成 enrollment。
  独立 OCI 固定官方 v1.102.5 标签与 digest，仍与 Nix 1.102.1 分开发布。
- 子网路由角色迁移需要新宣告获批、物理出口可达及所有旧网段验收后，再撤旧宣告。
  它与 Tailscale client、exit-node、普通 L3 路由角色分别处理。

## Transport guard 的三层边界

版本升级修复分片接收，不会自动消除嵌套 transport。需分别看三个位置：

1. **本机 TUN 捕获**：sing-box 的 provider process bypass 可防止本机重新捕获
   provider 的出站流量，但“交给物理默认路由”不等于后续路径没有 overlay。
2. **本机 Tailscale 策略路由**：内核模式的 transport socket mark 可用于跳过自身
   table 52，并精确拒绝已确认递归的 endpoint 前缀。普通未标记的 subnet 业务保留。
3. **容器与下游路由节点**：mark/进程身份不是线上 IP 字段，下一台机器不能继承它们；
   那里的 accepted routes 或 OSPF 路由仍可能把 UDP 送入另一条隧道。

还需纠正只看 Listener 实现得出的推断：在已核对的 1.98.5 与 1.102.1 中，
`tailscaled` 为 `userspace-networking` 调用 `netns.SetEnabled(false)`。
这关闭的是 Go netns 的 Control hook；不能因为 Listener 的共享代码支持 SO_MARK，
就假定 userspace 实际 socket 已带 mark。当前 userspace 实测也未见该 mark。

- [v1.102.1 启动选择](https://github.com/tailscale/tailscale/blob/v1.102.1/cmd/tailscaled/tailscaled.go#L809-L811)
- [netns Listener](https://github.com/tailscale/tailscale/blob/v1.102.1/net/netns/netns.go#L90-L98)

因此，现有 kernel fwmark guard 继续保留，并应拒绝在这类 userspace 配置上静默启用。
不能给整个 daemon 的私网出站一律打标或阻断：同一 userspace 进程还会建立正常
subnet TCP/UDP 代理 socket。全局封 UDP/41641 也不是可靠分类，端口会变化。

下一步宜先验证真实 underlay：如果中间节点经物理网关能到达目标 LAN，就将这些
本地物理路由置于 accepted overlay 路由之前；这对不同 mesh 后端都有效。
若确实只能经 overlay 到达，则需在 transport 发起端区分 socket/出口，或者分离
transport endpoint 地址面与业务 subnet 地址面。仅绑定物理接口或移动到 netns，
而沿用同一个会递归的下游网关，不能完成这个保证。

canary 的验收应同时证明：transport 不再出现在中间 overlay 接口、普通 subnet
TCP/UDP 仍通、合法 LAN/公网 direct 不被误伤，并在 direct 不可用时允许 DERP。
这层策略尚未部署，不能以低 MTU、升级成功或 subnet-router 归属迁移代替其验收。

### 后续原生路径 canary

10 月 3 日另外验证了真实物理出口。最初只能访问路由器自身地址，转发到目标主机的
诊断流量被默认 WAN→LAN ACL 拒绝；仅放行指定诊断源和目标后，IP1500、DF 的 ICMP
及目标 SSH banner 可达。可达的网关不等于其网段所有业务已完成验收。

随后只为原 transport UDP tuple 临时选择原生下一跳，配套窄范围 ACL 与自动撤销。
客户端与接收端保持 1.98.5、默认 MTU：1253/1400 disco 和默认 SSH 3/3 成功。
同一流从物理接口进入、从物理接口退出，未进入中间 overlay。
撤销临时规则、诊断 conntrack 并恢复 redirect 设置后，默认 SSH 再次超时。

这说明当前路径确有原生 underlay，只是被策略路由与 ACL 遮住；不能继续概括成
“私网 endpoint 只有 overlay 可达”。软件升级修复接收缺陷仍保留，原生路由与访问
范围应另行声明化。canary 没有留下永久路由或放行规则。

[返回 Tailscale 排查索引](./README.md)
