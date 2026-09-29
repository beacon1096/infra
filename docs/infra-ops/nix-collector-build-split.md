# nix-collector / nix-builder 拆分设计基线

本页是「把 Forgejo runner 从构建机剥离、构建机退化为标准 Nix remote
builder」的方案基线，供跨 agent 评审与后续实施引用。它与
[Agent 构建信任](../agentic/workflow/infra-ops/agent-nix-build-trust.md) 的中期方向
一致：runner 承担控制/求值，构建交给一组无状态 remote builder，Attic 仍是唯一
持久 cache。

状态：**Phase 1a 已实施并验证**（2026-09-29，release 路径在 collector 上跑通），
Phase 1b（收编 PR runner）待做。评审记录（ChatGPT 审查）已折入本页；实施与运维
发现见文末[实施记录](#实施记录2026-09-29)。

## 现状

- Forgejo（`forgejo.beaco.works`）与 Attic（`nix.beaco.works`，cache `nix-fleet`）
  都在万象。
- Forgejo runner 直接跑在构建机上：太初 `nixbuilder-01/02/03`（Harvester VM，
  VLAN 1096，`172.16.101.31-33`，标签 `nix-builder:host`）、光谷 `gen10plus`
  （同标签，另承担 OSPF / Tailscale subnet router / exit-node / relay 等）、
  `beacon-mac-mini-m4`（`nix-builder-aarch64-darwin:host`）。
- 工作流在构建机本机执行：checkout → `attic login` → `nix build --keep-going`
  （输入从 Attic substitute）→ best-effort `attic push` → registry/ISO 发布。
  见 `.forgejo/workflows/build-and-push.yaml`、`.forgejo/workflows/check-nix.yaml`。
- 构建机因此同时是 runner、求值器、nix-daemon、本地 store、Attic 客户端，并持有
  Forgejo token、SOPS 主机密钥与 Attic 读写凭据。
- 根盘已改为 disposable 单副本：`terraform/harvester/main.tf` 的
  `nixbuilder-local` StorageClass（`numberOfReplicas=1`、RWO、`auto_delete`、
  按 `active` 决定 `Halted`/`RerunOnFailure`）；这解决了 Longhorn 3 副本与快照
  膨胀导致的磁盘压力，是本次拆分的前提。

## 目标

1. **消除重复构建**：已缓存的派生不重建（Nix 输入寻址 + Attic substitution 天然保证）。
2. **允许重复传输**：collector 可以直接从 substituter 大量拉取，即使最终无新内容可
   seed；这一浪费仅落在万象集群内网与磁盘 IO，不属本需求硬目标。是否用「缓存完备性
   短路」（D9）消除，作为可选优化单独评估。
3. **身份/信任拆分**：求值、seed、发布收敛到 Attic 旁的万象 collector；太初构建机
   退化为无状态 remote builder，去掉 **写权限**（Forgejo token、Attic write、registry
   write、部署凭据），保留 scoped Attic **read**。
4. **托管 Attic 仍是唯一权威持久 cache**；collector 的 store 只是 working set，
   不是第二级 cache。
5. **不新增 VM 生命周期管理**：构建机常驻在线，用标准 `nix.buildMachines` 派发。
6. **缩小首次切换的故障域**：先只改 release 路径，PR 与 `gen10plus` 暂不动。

## 非目标

- 不实现构建机按需启停 / 自动伸缩控制器。
- 不建设第二套持久缓存。
- 不把 `gen10plus` 纳入 Phase 1 build pool。
- 不改动 Mac / darwin 路径（另案：拆 aarch64-linux 与 darwin 标签）。

## 架构

```text
万象
   nix-release-collector  (Forgejo runner, label: nix-collector:host)
    ├─ 自定义镜像 forgejo-runner-nix（forgejo runner + Nix 等）；host 模式，无 DinD
    ├─ 有界 Nix working store（需容纳最大单个 artifact）
    ├─ distributedBuilds = true; max-jobs = 0 (preferLocalBuild 例外)
    ├─ build-machines = 太初三台 (ssh-ng, maxJobs = 1)
    ├─ Attic: http://attic.nix.svc.cluster.local:8080/nix-fleet
    │         read 常驻 / write 仅 seed step
    └─ registry write 仅 publish step
太初 nixbuilder-01/02/03
    ├─ nix-daemon + nixremote SSH（接受 collector key, trusted-users）
    ├─ 保留 Forgejo runner（Phase 1a 期间 PR 仍走这里）
    ├─ read-only Attic token（或 is_public 匿名读）
    └─ max-jobs=1 / cores=4 / min-free=12Gi / max-free=32Gi
```

`builders-use-substitutes = true` 下，构建机先用**自己的 substituter** 拉输入，
collector 不必持有完整输入闭包；collector store ≈ output 闭包 + 不可替换输入 +
artifact。

## Collector 运行时选型：host 模式，无 DinD

结论（2026-09-28）：collector 采用 **Wrenix forgejo-runner chart 底座 + host 模式 + 自定义含
Nix 镜像**，**不保留 DinD**。原 `wanxiang/kubernetes/apps/forgejo-runner/`（DinD、
`replicaCount: 0`）撤掉。

理由与背景：

- stock `code.forgejo.org/forgejo/runner` 镜像不含 Nix，host 模式无法跑 `nix build`，故需一层
  自定义镜像（`packages/forgejo-runner-nix`）。
- 旧 runner 是 chart 0.7.6 的 DinD 形态（`runner` + privileged `dind`；`runner` 启动时在
  `127.0.0.1:2376` 等 dockerd），历史上一次 privileged DinD 构建绕过嵌套资源边界、打爆了
  控制面节点，故停用。
- 「rootless DinD」不是干净出路：Docker 官方 `dind-rootless` 在外层仍要求 `--privileged`
  （关 seccomp/AppArmor/mount mask），因此 **rootless engine ≠ 非特权 Pod**。
- 术语分层：rootless container engine / unprivileged outer Pod / user-namespaced Pod
  (`hostUsers:false`) / sandboxed runtime (Sysbox/gVisor/Kata) / daemonless image builder
  (Buildah/kaniko) 是不同维度，不能混称「unprivileged dind」。
- BuildKit/kaniko/Buildah 只产出镜像，**不能替代** act_runner 的 `container:`/`services:`/
  `uses: docker://` 生命周期后端。

已实测前提（2026-09-28）：

- 万象 Pod 可达 `172.16.101.31:22`（builder）、`172.16.100.250:22`、`attic.nix.svc:8080`、
  `forgejo-http.development.svc:3000` → collector 无需 hostNetwork/sidecar。
- collector→builder 的 `nix store ping --store ssh-ng://beacon@172.16.101.31` → `Trusted: 1`。

安全边界原则（写入评审）：**资源限制是防事故措施；`privileged:false` / userns / VM 边界才是
安全边界——不要让前者承担后者。**

未来「容器化 / 定制 CI」另开 profile（不挂在 collector 上）：`container-ci` = act_runner +
**rootless Podman** 的 Docker-compatible socket（Forgejo 官方支持）+ `hostUsers:false` +
普通 Cilium 网络（`hostUsers:false` 与 `hostNetwork:true` 互斥）+ `capacity:1`。若 Podman
兼容性不达标，再评估 Sysbox；需要更强隔离且要完整 Docker 语义时用 Kata 或独立 disposable VM。
privileged DinD 若作为 fallback，必须节点级隔离（dedicated node/VM）+ 明确 CPU/mem/
ephemeral-storage/PID 总上限 + `capacity:1`。

### Talos 兼容性（调研 + 实测，2026-09-28）

实测（本集群）：

- Talos v1.13.10、kernel `6.18.48-talos`、containerd `2.2.7`；k8s `v1.36.4`。
- **unprivileged userns 已开启**：`user.max_user_namespaces = 11255`，由
  `wanxiang/talos/patches/global/machine-sysctls.yaml` 设定（非默认关闭）。
- Cilium 已是 `bpf-lb-sock-hostns-only = true`（Kata/gVisor 的 socketLB 前提已满足）。
- 已装 extensions：`intel-ucode / iscsi-tools / util-linux-tools / schematic`；
  **未装 gvisor / kata**（启用需改 schematic 重出镜像并重启节点）。

候选分层（本集群视角）：

| 方案 | 状态 | 需 userns | 节点改动 | Pod privileged | 定位 |
| --- | --- | --- | --- | --- | --- |
| host-mode collector | 原生 | 否 | 无 | 否 | 本项目采用 |
| K8s `hostUsers:false` | 1.36 可用 | 是（已开） | 无 | 否 | 额外隔离层；与 hostNetwork/PID/IPC 互斥；NFS 不支持 |
| gVisor (`runsc`) | Talos **core** extension，需安装 | 是（已开） | schematic 重装 + 重启 | 否 | 通用 sandbox / RuntimeClass |
| Kata | Talos **extra** extension，需安装 | 否 | schematic + KVM | 否 | 最强 blast radius（1.13 为 `handler: kata`/Cloud Hypervisor；`kata-qemu` 属 1.14） |
| rootless Podman | POC（非 turnkey） | 是（已开） | 无 | 目标否 | Forgejo `container:`/`services:` 候选 |
| rootless BuildKit / Buildah | POC；seccomp 现实坑 | 是（已开） | 无 | 可非 privileged，常需 seccomp Unconfined | 仅镜像构建 |
| kaniko | 普通 Pod 可跑 | 否 | 无 | 否 | 最省事的 Dockerfile→镜像 |
| rootless Docker / `dind-rootless` | **排除** | 是 | — | **是（官方仍要 outer privileged）** | 不满足硬约束 |
| Sysbox | **排除** | 自身大量用 userns | 自维护 runtime/daemon | workload 否 | 无 Talos extension，支持表未含 1.36 |

结论：

- collector 保持 host-mode，**不需要 userns**；本集群 userns 已开，故 `hostUsers:false`、
  rootless Podman、gVisor 都**不存在“内核/策略未开”的前置障碍**。
- 一般镜像构建 CI：先 kaniko，其次 rootless BuildKit（需明确接受 seccomp /
  `user.max_user_namespaces` 的维护成本）。
- Forgejo 完整容器化 CI（`container:`/`services:`/`uses: docker://`）另开 `container-ci`
  profile：POC rootless Podman（`runc` 与 `Kata` 两种边界）。
- gVisor / Kata 作平台能力（RuntimeClass），需先改 Talos schematic 安装 extension。

POC 顺序与验收：

1. Phase 0：普通 runc Pod + host-mode collector。
2. Phase 1：`hostUsers:false` 冒烟（确认 Talos userns + volume idmap）。
3. Phase 2：gVisor / Kata RuntimeClass 冒烟 + **Cilium 连通性**（CoreDNS、Forgejo/Attic/zot
   ClusterIP、Internet、MTU）。
4. Phase 3：rootless Podman + Forgejo 兼容 fixture（`container:`、多个 `services:`、service
   DNS/alias、`docker://` action、volume/workspace、并发取消清理）。
5. Phase 4：**故障注入**（fork bomb、内存压力、CPU 饱和、大镜像拉取/填盘、孤儿嵌套容器、
   job 取消）。

验收标准：**恶意/失控 CI job 吃满其执行环境的 CPU/mem/PID/ephemeral-storage 时，ms01 上
kubelet/etcd/Cilium 及其它 workload 仍正常。** 三台 ms01 均控制面，故「CI 可消耗资源上限」作为
独立防线保留——RuntimeClass 解决 privilege/kernel blast radius，不解决 node resource starvation。

## Phase 1a：只改 release 路径

- 万象新增 `nix-release-collector`（Forgejo runner，label `nix-collector`，
  `capacity=2` 起步，非特权、独立 namespace、资源与磁盘限额）。
- `build-and-push.yaml` 中 release 相关 job 的 `runs-on: nix-builder` 改为
  `nix-collector`；`check-nix.yaml` 与 PR 路径不动。
- 太初三台**保留** Forgejo runner（PR 仍在其上执行，现状无写凭据），保留 read-only
  Attic 凭据，新增接受 collector remote-build SSH。
- `gen10plus` 不加入 build pool。
- `ATTIC_TOKEN` 从 workflow 顶层 `env` 拆为：read 常驻、write 只注入 seed step。

### Phase 1a 落地清单（file-level）

公开仓：

- 自定义镜像 `packages/forgejo-runner-nix`（`dockerTools.buildLayeredImage`：`nix` +
  `forgejo-runner` + `attic-client` + git/jq/curl/ssh…；**不烘焙拓扑/密钥**）；flake 暴露
  `forgejo-runner-nix-oci`。
- 新增 `wanxiang/kubernetes/apps/nix-collector/`（新 namespace）：**Wrenix chart 0.7.6**，
  `image` = `forgejo-runner-nix`（经 registry/zot 拉），
  `runner.config.file.runner.labels: ["nix-collector:host"]`、`capacity: 2`、`timeout: 12h`、
  `securityContext.privileged: false`。postRenderer：
  - 删除 dind 容器（`containers[1]`）；
  - 覆盖 runner 容器 `command` 为直接
    `/bin/forgejo-runner --config /etc/runner/config.yaml daemon`（去掉 chart 的“等 2376 dockerd”）；
  - 去掉 `DOCKER_*` env；
  - 挂 `nix.conf`(ConfigMap)、Attic netrc(Secret)、builder SSH key(Secret)。
- 注册用新的 init secret（SOPS：`CONFIG_TOKEN`/`CONFIG_INSTANCE`/`CONFIG_NAME`）。
- 撤掉 `wanxiang/kubernetes/apps/forgejo-runner/` 及其 namespace，并在 Forgejo 注销 talos-ii runner。
- 镜像发布：`build-and-push.yaml` 加 job，把 `forgejo-runner-nix` 推到
  `forgejo.beaco.works/infrastructure/nix-fleet/forgejo-runner-nix`。
- collector 的 Nix 配置（经挂载的 `nix.conf`）：`distributedBuilds = true`、`max-jobs = 0`、
  Attic substituter（集群内 `http://attic.nix.svc.cluster.local:8080/nix-fleet`）与
  `netrc-file`、`http2 = false`。机器规格每台 8 列、以 `;`（或换行）分隔：
  `ssh-ng://nixremote@172.16.101.31 x86_64-linux - 1 1 big-parallel,kvm - -`，
  列序为 `<uri> <system> <ssh-key> <max-jobs> <speed-factor> <supported-features>
  <mandatory-features> <base64-host-key>`。**空格分隔的「多台」会被解析成单台机器**
  （构建期报 `invalid character in Base64 string`），见[实施记录](#实施记录2026-09-29)。
- 有界 working store：`emptyDir` + `sizeLimit`（或小 PVC），能容纳最大单 artifact
  （installer-iso / OCI）。
- `.forgejo/workflows/build-and-push.yaml`：release 相关 job（`warm-cache`、
  `build-systems`、`warm-cache-arm`、`build-arm-systems`、`build-darwin-systems`、
  `build-installer-iso`、`build-and-push-*-oci`）`runs-on` 从 `nix-builder` 改为
  `nix-collector`；`check-nix.yaml` 及 PR 路径不动。

私有仓：

- `hosts/server/nixbuilder/common.nix`：新增 `users.users.nixremote`（authorized key =
  collector 的专属构建 key），加入 `nix.settings.trusted-users`；Phase 1a 仍保留
  Forgejo runner 实例（PR 用）。
- 三台 builder 保留 read-only Attic 凭据；不新增写权限。

验收：

- `nix store ping --store ssh-ng://nixremote@172.16.101.31`（以 collector 内运行
  nix-daemon 的身份）。
- release job 落到 collector，派生实际在三台 builder 执行，store path 一致。
- 最大 artifact 构建后 collector working store 可回收。

## Phase 1b：收编 PR runner（1a 稳定后）

- 新增只读 `nix-check-runner`（label `nix-builder`）或把 PR 落到只读 collector，
  再摘除太初的 Forgejo runner。
- 处理 PR 特有风险：
  - eval 非沙箱：IFD、`builtins.fetchurl` 以 runner 身份在 collector 执行。
  - FOD 允许网络访问：限制构建机 VLAN 只放 Attic/DNS/必要公网 egress，禁管理网段。
- 可选：`attic watch-store` 先在 release collector 试（Phase 1.1），
  **绝不与 PR working store 混用**，否则 PR 产物会被自动写入可信 Attic。

## Builder 身份与 Interactive builder

### 两类 builder，身份与池都不共用

| 类别 | 用途 | 形态 | store | GC | 身份族 |
| --- | --- | --- | --- | --- | --- |
| CI builders | 本方案 | disposable（太初三台） | 有界 | 构建后可清 | `ci-release` / `ci-pr` 分族 |
| Interactive builders | 改内核等 ad-hoc 测试 | 持久、大磁盘、可选 `kvm`/GPU | **保留缓存** | 宽松，不主动清 | `fleet-adhoc` |

ad-hoc 构建通常需要 egress、可写持久 store，有时需要 `kvm`（nixos-test）；这与 CI
builder「无状态、可清、受限 egress」相反，必须分池。

### 现状身份混乱

- `modules/common/remote-builder.nix:5,20,36` 把 `gen10plus`（tailnet `100.121.229.9`）
  硬编码成全机队默认 remote builder，`maxJobs=8`、`supportedFeatures=[big-parallel kvm]`，
  走 `sshUser = "beacon"`。
- 同一台 `gen10plus` 又开着 `users.users.nixremote`（多个 host key）且
  `trusted-users=["nixremote"]`，同时还是 Forgejo runner 与网络/边缘主机。
- 即同一主机叠加多种角色、两套构建身份。

### 信任等价

能让 builder 接收 derivation 的身份 ≈ 该 builder 的特权（`trusted-users` 可导入不受信
store object、改 substituter）。因此：

- 太初 `nixbuilder-*`（disposable、无秘密）可接受；
- `gen10plus`（边界/网络主机）**不得**授予通用或 CI builder 身份。

### 目标形态

1. 统一 builder 身份（`nixremote` 式），`trusted-users` 只含它；
   `remote-builder.nix` 从硬编码 gen10plus 改为引用 builder 注册表 / role，并使用专属
   身份而非 `beacon`。
2. client key 按类别分族（`fleet-adhoc` / `ci-release` / `ci-pr`），builder 的
   `authorized_keys` 按族授权，独立撤销与轮换。
3. CI 与 interactive 分池：release collector 的 `buildMachines` 只指向 CI builders。
4. `gen10plus` 长期只做网络/边缘；interactive builder 迁到独立实体（专用持久 VM 优先，
   或 gen10plus 上的 VM，或保留现状并记录信任等价）。

## 关键决策点

| 编号 | 决策 | 倾向 |
| --- | --- | --- |
| D1 | 构建机 Attic 读方式 | `is_public` 匿名读，或 SOPS 注入 scoped `--pull` token |
| D2 | collector → 太初 网络形态 | Tailscale **subnet route**（不登录 gen10plus）优先；ProxyJump 仅作备选，且跳板用户不入 `trusted-users` |
| D3 | `gen10plus` 何时入池 | Phase 1 一律不入；除非明确记录「remote-build 凭据 = gen10plus 特权凭据」 |
| D4 | 失败构建的 partial seed | 见下「失败语义」 |
| D5 | PR runner 实体 | Phase 1a 保留太初 runner；1b 再引入只读 runner |
| D6 | Builder 身份 | 统一 `nixremote` 式身份，client key 按 `fleet-adhoc`/`ci-release`/`ci-pr` 分族 |
| D7 | CI / interactive 分池 | 分池且不共用身份；interactive builder 持久、保留缓存 |
| D8 | Builder 构建后清理 | `min-free`/`max-free` 为主 + 可选空闲显式 GC；不用重启 VM 清理 |
| D9 | 缓存完备性短路（可选优化） | 见「可选优化」一节；metadata-only 判断是否已有等价缓存 |
| D10 | collector 运行时 | host 模式 + 自定义 `forgejo-runner-nix` 镜像，**无 DinD**；撤掉旧 `forgejo-runner` app |
| D11 | 容器化 CI 的边界 | 另开 `container-ci` profile（rootless Podman + `hostUsers:false` + Cilium + `capacity:1`）；privileged DinD 仅作有节点级隔离的受限 fallback |

## 失败语义变化（必须显式决策）

现有 `build-and-push.yaml` 的 partial seed 依赖「失败构建的中间产物在本地 store」：
`grep nix-build.log` → `nix path-info` 验证 → `attic push`。改为 remote build 后，
中间产物留在**构建机**的 store，collector 上没有对应路径，日志 grep 也找不到，
该逻辑会静默漏掉。

候选处理：

- (a) Phase 1a 接受「失败构建不 seed 中间产物」；
- (b) collector 对失败 drv 执行 `nix copy --from ssh-ng://<builder>` 拉回后再 seed；
- (c) `attic watch-store`（需写权限，只能用于 release collector）。

不得为了让 (c) 生效而把 Attic write 权限放回构建机。

## 可选优化：缓存完备性短路（D9）

问题：每次 workflow 都会把整个闭包 substitute 进 collector store，即便所有 output
已在 Attic、无需构建也无需 seed，仍会消耗集群内网与磁盘 IO。

**采用 positive fast-path，不做缺失规划**：只在能证明 Attic 中目标 runtime closure
完整时短路；任何 miss、异常或不确定，一律整体回退到现有 `nix build → attic push`。
之所以不能反过来「自己算缺失集合」，是因为 metadata-only 下 partial miss 不可判定
（缺失的 narinfo 连它的 `References` 也一起缺失）。

判定（仅元数据，不下载 NAR）：

```text
evaluate（仍会 fetch flake inputs；IFD 例外）
  → 得到最终 output path(s)（nix eval --raw .#<attr>.outPath，多 output 逐个）
  → nix path-info --store <Attic>/nix-fleet --recursive --refresh <roots>
       全部成功 → HIT：跳过 substitute + build + seed
       任意失败/异常 → 回退完整 nix build + attic push
```

要点与 caveat：

- `--refresh` 必须加。Nix 默认缓存 narinfo（positive 约 30 天、negative 约 1 小时），
  否则 Attic GC 后的 stale positive 会导致误判。
- 必须覆盖 runtime closure，不能只看顶层 path。
- 「narinfo 存在」≠「NAR bytes 健康」；Attic DB 与底层 chunk 不一致是 metadata-only
  无法发现的，结论只到「Attic metadata index 认为完整」。
- IFD / 浮动 CA derivation：eval 阶段可能已经真实 realise，或 output path 尚未知，
  此时直接回退。
- **短路范围只限 Nix build + seed**：registry push、release、`prod` 更新等副作用不受
  Attic 命中影响，不能一并跳过。OCI job 即便 Attic 命中仍需本地归档才能 `skopeo copy`，
  对其短路收益有限。
- 前置核对：`nix path-info --store <cache>` 的签名 / `trusted-public-keys` 行为；
  `attic cache info nix-fleet` 的 upstream filter 是否为空；`nix-fleet` 的 retention
  是否保证 deploy 仍需的闭包不被自动淘汰（否则 probe 通过后仍可能被 GC）。
- 第二阶段（L2）才考虑以最终 store path 为 key 记忆化 + Attic `get-missing-paths`
  批量 API；该 API 需要 push 权限，且第一版不应耦合 Attic 私有接口。

原型：`.forgejo/workflows/attic-closure-probe.yaml`（仅 `workflow_dispatch`、只读、不改变
现有 CI）。本地已用公开 cache 验证 `nix path-info --store -r --refresh` 只读元数据、
命中/缺失/未鉴权三种返回符合预期。

曾集成到 release 路径（PR #138），**后已移除**（PR #149）：实测 preflight 让
`warm-cache` 从 ~43s 拉长到 ~57m（逐 path 查询 Attic），收益不抵开销，故回退为无短路。
`.forgejo/workflows/attic-closure-probe.yaml` 仅保留为手动只读工具。

Phase 1a 连通性前置已实测：从可路由太初的主机执行
`nix store ping --store ssh-ng://beacon@172.16.101.31` → `Trusted: 1`（builder 作为
remote build target 成立；`nixremote` 专属身份仍待 Phase 1a 引入）。

## 实施记录（2026-09-29）

Phase 1a 已落地并在 release 路径验证通过。collector 以 host 模式（无 DinD）运行自定义
镜像 `forgejo-runner-nix`，`max-jobs = 0`，经 `ssh-ng` 把派生派发到太初三台；
`warm-cache`、`build-systems`、`build-installer-iso` 与三个 `build-and-push-*-oci`
均落到 collector（label `nix-collector:host`）。运维发现：

- **机器规格必须 `;`/换行分隔**：`builders` 值以空格分隔多台时被解析为**单台**机器，
  第二台的 URI 落到 mandatory-features 列、system 落到 base64 host-key 列，构建期
  build hook 报 `invalid character in Base64 string`。正确写法见 Phase 1a 清单。
- **collector 内存**：`capacity = 2` 下并发两个 `nix build .#nixosConfigurations.<host>`
  求值会 OOMKill（4 GiB 限制，exit 137）并中断 job；已提到 **12 GiB** / request 2 GiB。
- **registry 推送**：大镜像层经公网 `forgejo.beaco.works`（Cloudflare tunnel）chunked
  上传返回 `502 Bad Gateway`，重试耗尽后 job 失败；collector 上的 OCI job 暂改走集群内
  `http://forgejo-http.development.svc.cluster.local:3000`（`--tls-verify=false`）。
  这是权宜之计，目标是在自建入口/反代上恢复单一、带校验证书的 registry endpoint，
  见 `TODO.md`「容器镜像推送入口」。`build-and-push-nix-collector-oci` 跑在集群外
  （Taichu），仍走公网 endpoint。
- **collector store 种子未导入 Nix DB（遗留）**：300 GiB PVC 的种子是文件级拷贝，
  个别路径未注册（`9jsz…-nix-2.34.8` 为 `not valid`），曾把不完整闭包发给 builder，
  导致远端 `nix: error while loading shared libraries: libboost_url.so.1.89.0`。需让
  种子导入 Nix DB，或跑 `nix-store --verify --repair` 重新注册。
- **ATTIC write 尚未收敛（遗留）**：`ATTIC_TOKEN` 仍在 workflow 顶层 `env`，Phase 1a
  清单要求的「read 常驻、write 仅 seed step」尚未落地。
- **旧 `wanxiang/kubernetes/apps/forgejo-runner/` 仍在（遗留）**：talos-ii runner 未注销。

Phase 1b 待做：新增只读 PR runner 或把 `check-nix.yaml` 落到只读 collector，再摘除
太初 Forgejo runner；同时处理 PR 特有风险（eval 非沙箱、FOD egress 边界）。

## 验收

- **连通性（先是硬门槛）**：从实际运行 nix-daemon 的身份执行
  `nix store info --store ssh-ng://nixremote@172.16.101.31`，而非普通 shell；
  host key 预先 pin，不在首次连接现场 accept。
- **拆分生效**：release job 落到 collector，派生实际在太初三台执行，store path 一致。
- **短路**：输入未变时二次运行不派发构建（可重新拉取，但不重建）。
- **working store 有界**：跑最大 artifact（installer-iso / OCI）后 GC 能收缩。
- **Longhorn + trim**：`nix-collect-garbage` 后执行 `fstrim /`，确认
  Longhorn `actualSize` 回落或趋稳。当前 `hosts/server/nixbuilder/disko.nix` 为普通
  ext4、无 trim，需启用 `services.fstrim.enable` 或 Longhorn recurring filesystem-trim，
  否则会误判为 store 泄漏。
- **资源边界**：构建机侧 `max-jobs=1` / cgroup 是最终边界（多 coordinator **无全局
  队列**，每个 coordinator 都以为自己独占 these builders）。

## 风险

1. 反向连通性不通过则整个数据面不成立。
2. `max-jobs = 0` 不阻止 `preferLocalBuild = true` 的派生本地执行；需抽查本仓库
   哪些 output 走此路径（镜像/import-from-derivation 类），不能假设「绝不本地 build」。
3. 把 remote-build 身份的 key 变成 `gen10plus` 的 nix `trusted-users` 等价于
   授予近似 root：`trusted-users` 可导入不受信 store object、改 substituter。
4. collector 若持有 Attic write + registry write 又跑 PR，会把 PR 代码与写凭据
   放在一起；必须靠 D5 隔离。
5. 非受信 PR 的 FOD 是构建机 egress 的信任边界，不只是「没网会构建失败」。

## 关联

- [Forgejo Runner nix-builder 维护窗口](./runner-maintenance.md)
- [Agent 构建信任](../agentic/workflow/infra-ops/agent-nix-build-trust.md)
- [生产发布与 Nix 滚动部署](../agentic/workflow/infra-ops/production-release-and-rollout.md)
- Attic 运维（集群内地址、优先级、`is_public`）：私有仓万象运维文档；
  公开摘要见 `wanxiang/docs/operations/attic-restore.md`。
