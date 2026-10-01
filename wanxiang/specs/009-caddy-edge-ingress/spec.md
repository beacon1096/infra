# 功能规格：自建 Caddy 边缘作为高带宽入口

**功能分支**：`009-caddy-edge-ingress`
**创建日期**：2026-09-30
**状态**：草稿
**输入**：用户请求：“正式推进 Caddy 反代流量入口：解决 OCI 推送 Cloudflare 524 与 CI attic 推送 502。参考讨论: https://chatgpt.com/share/6abd72ae-519c-83ea-ab8d-d58dc322262f”

## 范围

把自建 Caddy 边缘正式确立为站点侧反代入口——即 Cloudflare Tunnel
默认之外的按服务 VPS 例外——并把公网 Cloudflare 路径无法可靠承载的两条路径
迁到该边缘：

- **容器镜像推送**到 Forgejo registry（`forgejo.${SECRET_DOMAIN}`）：大镜像层
  分块上传返回 Cloudflare `502`，约 130 MiB 的 collector 镜像被以 `413` 拒绝。
- **Nix 二进制缓存推送**到 Attic（`nix.${SECRET_DOMAIN}`）：近期 CI 闭包返回
  Cloudflare `502`。

Caddy 边缘已经终止公网 TLS（经 Cloudflare API 的 ACME DNS-01）并反代命名上游；
私有仓 `infra-private` 的边缘清单已声明指向 tailnet 内集群服务的 `forgejo` /
`registry` / `nix` 站点。缺的一步是让边缘对这些主机名**权威**（DNS），并让消费
端退役 Cloudflare 权宜手段。

本变更是**增量的、按主机名**的：只有列出的高带宽名称迁到边缘，其余
`*.${SECRET_DOMAIN}` 主机名继续走 Cloudflare Tunnel。

## 不在范围内

- 用 Caddy 取代 Envoy Gateway 作为 Kubernetes L7 入口。Envoy
  （`envoy-external` / `envoy-internal`）仍是集群内服务入口；边缘只是它前面的
  站点边缘，不是 Kubernetes 路由器。
- 迁移 mesh VPN 或改变 DNS locality / split-horizon 策略。
- 迁走非高带宽主机名，或做 `*.${SECRET_DOMAIN}` 通配切换。
- 改变 Cloudflare 为普通 Web 流量承载的主机名。

## 职责边界

设计讨论的分层划分（规格被接受后沉淀为长期 ADR）：

| 层 | 归属 | 职责 |
| --- | --- | --- |
| Kubernetes 服务入口 | Envoy Gateway（`envoy-external` / `envoy-internal`） | `HTTPRoute` → `Service`、集群内 TLS、HTTP/3、重试 |
| 站点边缘 | 自建 Caddy 边缘（私有） | 公网 TLS、主机名、反代到 mesh 可达上游、WebSocket/HTTP2/HTTP3、健康检查/failover；为无 mesh 客户端的设备提供入口 |
| 站点互联 | Mesh VPN（tailnet） | 边缘与集群之间的 L3/L4 传输 |
| 名称解析 | DNS | locality 选择（split-horizon） |

Caddy 不得接管 Kubernetes 服务路由；Envoy 不得依赖边缘。边缘只拨号一个
mesh 可达上游，不需要知道 mesh 的实现方式。

## 用户场景与测试

### 用户故事 1 — 集群内 CI 推送大镜像（P1）

`nix-collector` runner 通过单一带校验证书的 endpoint 推送数百 MB 的 OCI 镜像，
不经 Cloudflare，也不关闭 TLS 校验。

**优先级理由**：这是阻塞发布的实际故障（524/502/413）；没有它本工作项就没有
验收信号。

**独立测试**：在 runner 上以默认 TLS 校验把大的 `coding-agent-oci` 镜像
`skopeo copy` 到公网 registry endpoint，并把 manifest 拉回。

**验收场景**：

1. **给定**边缘对 registry 主机名已权威，**当**CI 推送超过 Cloudflare body
   上限的层，**则**推送以 HTTP `2xx` 完成，无 `502`/`413`。
2. **给定**同一推送使用默认 TLS 校验运行，**当**客户端校验证书，**则**校验
   成功（无需 `--tls-verify=false`）。
3. **给定**推送目标是公网 registry 主机名，**当**检查时，**则**endpoint 是单一
   主机名，而不是硬编码的 `*.svc.cluster.local` 地址。

### 用户故事 2 — 集群外构建机走同一 endpoint（P1）

无法解析 `svc.cluster.local` 的太初 builder
（`build-and-push-nix-collector-oci`）使用同一带校验证书的公网 endpoint。

**优先级理由**：只服务集群内 runner 的修复会让集群外构建机留在 Cloudflare 路径。

**独立测试**：在太初 builder 上对公网主机名执行同样的 `skopeo copy`。

**验收场景**：

1. **给定**构建机在集群外，**当**它推送 collector 镜像，**则**推送对 runner
   使用的同一主机名成功。

### 用户故事 3 — CI 推送闭包到 Attic（P1）

CI 把大闭包推送到 `nix.${SECRET_DOMAIN}`，且不返回 Cloudflare `502`。

**独立测试**：`attic push` 一个至少数百 MiB 的闭包并确认可替换。

**验收场景**：

1. **给定**边缘对缓存主机名已权威，**当**CI 推送大闭包，**则**推送完成且该路径
   可替换。

### 用户故事 4 — 回滚只需还原 DNS（P2）

若边缘路径异常，运维可无数据损失地恢复 Cloudflare 路径。

**独立测试**：还原某个主机名的 DNS 记录并确认 Cloudflare Tunnel 路径恢复服务。

**验收场景**：

1. **给定**已切换，**当**DNS 记录被还原，**则**该主机名重新由之前的 Cloudflare
   路径服务，且集群工作负载无变化。

## 需求

### 功能需求

- **FR-001**：Caddy 边缘 MUST 为迁移的主机名提供有效的公网受信证书
  （ACME，不使用手工或自签证书）。
- **FR-002**：边缘 MUST 经 mesh（tailnet）上游到达其后端集群内服务；边缘与
  集群之间不得有公网跳。
- **FR-003**：每个迁移主机名的 DNS MUST 解析到边缘，而不是 Cloudflare Tunnel /
  Cloudflare 代理。
- **FR-004**：CI MUST 通过每个服务单一且带校验证书的 endpoint 推送 registry 镜像
  与 Attic 闭包，并使用默认 TLS 校验。
- **FR-005**：集群外（太初）构建机 MUST 使用与集群内 runner 相同的 endpoint。
- **FR-006**：所有未迁移的 `*.${SECRET_DOMAIN}` 主机名 MUST 继续经既有
  Cloudflare Tunnel 路径服务。
- **FR-007**：不得提交明文凭据；边缘 TLS 凭据仍留在边缘 SOPS 管理的环境中。
- **FR-008**：只有当边缘路径端到端验证通过后，才移除 Talos 节点对
  `forgejo.${SECRET_DOMAIN}` 的 `/etc/hosts` 覆盖，以及 CI 中
  `--tls-verify=false` 与字面 `svc.cluster.local` 的权宜手段。
- **FR-009**：切换 MUST 仅凭 DNS 可逆；不得删除或替换工作负载、存储或集群资源。
- **FR-010**：WebSocket 与 HTTP/2（以及迁移名称上的 HTTPS）MUST 继续经边缘工作。

### 关键实体

- **迁移主机名**：公网 zone 中从 Cloudflare 迁到边缘的 `forgejo` / `registry` /
  `nix` 名称。
- **边缘站点**：服务某个迁移主机名的声明式 Caddy 站点（`hosts` + `routes` +
  `upstream`）。
- **mesh 上游**：边缘拨号的 tailnet 可达后端。
- **CI endpoint**：发布工作流使用的 `REGISTRY_ENDPOINT` / `ATTIC_ENDPOINT`
  action 变量。

## 成功标准

- **SC-001**：在集群内 runner 上以默认 TLS 校验把大 `coding-agent-oci` 镜像
  `skopeo copy` 到公网 registry 主机名成功。
- **SC-002**：在太初构建机上执行同一推送成功。
- **SC-003**：把 >100 MiB 的闭包 `attic push` 到公网缓存主机名成功。
- **SC-004**：抽样的未迁移主机名经 Cloudflare 返回与变更前相同的结果。
- **SC-005**：还原 DNS 记录即可恢复 Cloudflare 路径，无需任何集群侧操作。

## 假设

- 私有 Caddy 边缘已声明 `forgejo` / `registry` / `nix` 站点并持有可用的
  Cloudflare DNS-01 token；本规格是让它们权威，而不是从零编写。
- tailnet 暴露的集群内 Forgejo、zot 与 Attic 服务仍可达，且是预期上游。
- 公网 zone 的 DNS 在本仓库之外的 Cloudflare 管理；记录变更由运维执行且需
  审批（网络核心边界）。
- Cloudflare 在 Tunnel 上的 body 大小 / 合理使用限制仍是这些高带宽路径需要边缘的
  原因；边缘没有此类 body 限制。
