# 实施计划：自建 Caddy 边缘作为高带宽入口

**分支**：`009-caddy-edge-ingress` | **日期**：2026-09-30 | **规格**：[spec.md](./spec.md)
**目标**：由自建 Caddy 边缘服务的万象（原 talos-ii）业务。

## 摘要

让自建 Caddy 边缘对高带宽主机名权威，并退役 Cloudflare 权宜手段：

1. 确认指定边缘节点已渲染并运行边缘站点（`forgejo` / `registry` / `nix`），
   具备有效的 ACME 证书与可达的 mesh 上游。该部分位于 `infra-private`；公开仓只
   记录策略与消费侧改动。
2. 把选定主机名的 DNS 记录从 Cloudflare Tunnel / Cloudflare 代理改指到边缘
   节点。**需审批**（网络核心）。
3. 更新 CI（`build-and-push.yaml`），通过单一带校验证书的主机名推送并使用默认
   TLS 校验；去掉 `svc.cluster.local` 字面量与 `--tls-verify=false`。
4. 边缘路径验证通过后，移除节点对 `forgejo` 的临时 hosts 覆盖与遗留权宜注释。

变更按主机名增量进行，仅凭 DNS 即可回滚。

## 技术背景

- **集群入口（不变）**：`envoy-external`（LB `172.16.87.11`，
  `external.${SECRET_DOMAIN}`）与 `envoy-internal`（`172.16.87.21`，
  `internal.${SECRET_DOMAIN}`；同时经 tailnet 暴露为 `internal-ingress`）。
  Cloudflare Tunnel 将 `${SECRET_DOMAIN}` 与 `*.${SECRET_DOMAIN}` 送到
  `envoy-external`；`cloudflare-dns`（external-dns）管理代理记录。
- **边缘（私有）**：来自 `infra-private/lib/edge-caddy` 的 NixOS 原生 Caddy，
  带声明式 `sites`/`upstreams`、经 Cloudflare API 的 ACME DNS-01，以及 tailnet
  可达上游。已声明：
  - `forgejo.<public-zone>` → `forgejo.<tailnet>:3000`
  - `registry.<public-zone>` → `zot.<tailnet>:5000`
  - `nix.<public-zone>` → `attic.<tailnet>:8080`
- **CI**：`.forgejo/workflows/build-and-push.yaml` 当前把
  `REGISTRY_ENDPOINT_INTERNAL` 默认设为
  `http://forgejo-http.development.svc.cluster.local:3000`，并在 host 匹配
  `svc.cluster.local` 时追加 `--dest-tls-verify=false` / `--tls-verify=false`。
  Attic 步骤使用 `ATTIC_ENDPOINT`。
- **节点权宜手段**：`wanxiang/templates/config/talos/patches/global/machine-network.yaml.j2`
  经 `/etc/hosts` 把 `forgejo.${SECRET_DOMAIN}` 覆盖到 `envoy-internal` LB IP，
  使节点级镜像拉取绕开 Cloudflare。
- **约束**：无破坏性变更、无明文密钥、不改非迁移主机名、不改 Kubernetes 服务路由。

## 合规

- **公网暴露**（宪法 §VI — Cloudflare Tunnel 默认，按服务 VPS 例外）：这是新增的
  按服务例外，且为增量添加。
- **GitOps**：集群资源保持声明式；DNS 变更记录在本规格与私有回滚说明中，不手改进
  集群。
- **公私边界**：边缘拓扑与主机选择留在 `infra-private`；本仓只承载策略与
  CI/Talos 消费侧改动。
- **镜像工厂 / 存储 / 机器配置**：不变。
- **密钥**：不新增明文凭据；边缘继续使用其 SOPS 管理的 Cloudflare DNS token。

## 决策与理由

- **用边缘而非更大的 Cloudflare 方案**：故障是 Tunnel 的 body 大小 / 分块上传
  限制，不是上游错误。自建反代没有 body 限制即可解决，无需升级 Cloudflare 付费档。
- **按主机名切换而非通配**：缩小爆炸半径，并让 Cloudflare 回退对其余名称仍有意义。
- **保留 Envoy 作为 Kubernetes 入口**：边缘只拨号 mesh 上游，不学习 Kubernetes
  路由，从而维持分层与既有 `HTTPRoute` 归属。
- **先迁 registry 与 Attic**：它们是已观测到的故障，且不是面向用户的 Web 会话，
  风险可控。
- **仅凭 DNS 回滚**：无数据迁移，无需撤销部署。

## 项目结构

```text
wanxiang/specs/009-caddy-edge-ingress/{spec,plan,tasks}.md
# 消费侧改动（本仓）：
.forgejo/workflows/build-and-push.yaml            # 单一 endpoint，无 TLS 绕过
wanxiang/templates/config/talos/patches/global/machine-network.yaml.j2
# 边缘与 DNS（infra-private，运维/审批门控）：
infra-private/lib/edge-caddy/...                  # 站点已声明
# Cloudflare DNS 记录：运维操作，记录在 PR/issue 中
```

## 风险

- **边缘单点故障**：若仅一个边缘节点服务迁移名称，边缘故障会阻塞 CI 发布。缓解：
  经不同主机名保留 Cloudflare 回退，和/或由多个边缘节点服务这些名称；记录回退方式。
- **证书签发依赖**：证书续期依赖边缘的 Cloudflare API token 与 DNS-01；需验证续期
  而不只是首次签发。
- **DNS 传播 / TTL**：切换并非瞬时；应在确认 DNS 已解析到边缘后再改 CI。
- **集群内客户端 hairpin**：集群内 runner 使用公网主机名时可能解析到边缘再经 mesh
  回环进入集群。需确认 runner 的解析路径，或在拉取侧保留节点内覆盖、仅在推送侧使用
  边缘 endpoint。
- **Attic 路径**：确认 Attic 客户端经边缘可用（分块 NAR 上传），而不只是 registry。

## 回滚

1. 把受影响主机名的 DNS 记录还原为之前的 Cloudflare 目标（受 TTL 约束）。
2. 若确认边缘路径不可用，还原 CI endpoint 改动（恢复
   `REGISTRY_ENDPOINT_INTERNAL` / 原 `ATTIC_ENDPOINT`）。
3. 无需回滚集群、存储或工作负载。

## 阶段

1. **确认边缘站点 + 证书 + 上游**（私有；不改 DNS）。
2. **审批门**：对选定主机名执行 DNS 记录变更。
3. **切换 CI** 到单一带校验证书的 endpoint；去掉 TLS 绕过。
4. **验证**大镜像推送、Attic 推送、集群外构建机，以及一个抽样的未迁移主机名。
5. **退役权宜手段**：推送与拉取都验证通过后，移除节点对 `forgejo` 的覆盖；随后把
   边界决策沉淀为 shared ADR。
