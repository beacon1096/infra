---
description: "自建 Caddy 边缘高带宽入口任务清单"
---

# 任务：自建 Caddy 边缘作为高带宽入口

**输入**：设计文档来自 `wanxiang/specs/009-caddy-edge-ingress/`
**前置**：spec.md、plan.md
**门控**：阶段 2（DNS）属网络核心，MUST NOT 在未获针对确切主机名与目标的明确
批准前执行。

## 阶段 1 — 确认边缘站点（私有；只读）

- [x] T001 确认指定边缘节点已从边缘清单渲染 `forgejo` / `registry` / `nix`
  站点，且运行当前 generation。
- [x] T002 确认边缘为目标主机名提供有效的公网受信证书，且已配置续期（DNS-01）。
- [x] T003 确认每个边缘上游可解析并经 mesh 连到集群内 Forgejo / zot / Attic
  （只读可达性检查）。
- [x] T004 记录待改的确切 DNS 记录（名称、当前目标、当前代理状态、TTL）与预期
  新目标。

## 阶段 2 — DNS 切换（需审批）

- [x] T005 就阶段 1/T004 的具体记录与目标获得明确批准。
- [x] T006 一次只改一个主机名；从 registry 主机名开始。
- [x] T007 从外部网络确认 `curl -I https://<host>/` 与证书链返回的是边缘而非
  Cloudflare。

## 阶段 3 — 消费侧改动（本仓）

- [x] T008 更新 `.forgejo/workflows/build-and-push.yaml`，让集群内与集群外构建机
  都使用单一带校验证书的 endpoint。
- [x] T009 endpoint 有效后，移除 `--dest-tls-verify=false` / `--tls-verify=false`
  逻辑与字面 `svc.cluster.local` 默认值。
- [x] T010 把 CI 的 `ATTIC_ENDPOINT` 指向边缘服务的缓存主机名。
- [x] T011 把描述 Cloudflare 502/413 权宜手段的 workflow 注释更新为描述边缘路径。

## 阶段 4 — 验证

- [x] T012 在集群内 runner 上以默认 TLS 校验把 >100 MiB 镜像 `skopeo copy` 到
  公网 registry 主机名。（CI run 2796 经边缘推送大镜像成功。）
- [x] T013 在太初（集群外）构建机上重复 T012 —— **N/A**：CI 推送在集群内 runner
  完成，经 `hostAliases` 走 `envoy-internal`，不存在集群外 push 路径。
- [x] T014 把 >100 MiB 闭包 `attic push` 到公网缓存主机名。（run 2796 attic seed 成功。）
- [x] T015 抽样一个未迁移的 `*.${SECRET_DOMAIN}` 主机名，确认仍走 Cloudflare
  路径且行为不变。（`wayback.beaco.works` 仍 `server: cloudflare`。）
- [x] T016 确认证书续期可用（不只是首次签发）。（边缘 `*.beaco.works` 有效期至 2026-11-20。）

## 阶段 5 — 退役权宜手段 + 记录决策

- [x] T017 复核 machine-network patch 中节点对 `forgejo.${SECRET_DOMAIN}` 的
  `/etc/hosts` 覆盖：结论是**保留**——它是刻意的 LAN locality（集群内走
  `envoy-internal`），移除反而会让节点拉镜像绕到公网边缘节点；仅刷新注释措辞。
- [x] T018 把职责边界沉淀为 shared ADR（`docs/decisions/shared/`）并在同一提交中
  更新索引。（见 `shared/0004-site-edge-and-ingress-boundaries.md`。）
- [x] T019 更新 `TODO.md` / `TODO_en.md`，标记已迁移条目并说明剩余主机名。
