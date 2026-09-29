# Attic 二进制缓存

Attic 是自建的 Nix 二进制缓存（全局去重 + GC），CI 构建的 closure 推入这里，工作站和构建机从它替换。它和 Forgejo 的 registry、release asset 是并列的一类「产物」。

## 部署

- 位置：wanxiang（Talos）集群，namespace `nix`；HelmRelease/Deployment `attic`（`app-template` chart，镜像 `ghcr.io/zhaofengli/attic`，digest 固定）。
- 存储：PVC `attic-store` 100 GiB（`longhorn-r3`），本地 backend，路径 `/var/lib/attic/store`。
- 元数据：CNPG 集群 `attic-pg`（Postgres）。
- 配置：整个 `server.toml` 在 SOPS Secret `wanxiang/kubernetes/apps/nix/attic/app/secret.sops.yaml`，属于声明式管理。
- 入口：`https://nix.beaco.works`（Cloudflare Tunnel，有 body 大小限制）、`http://attic.tail5d550.ts.net`（tailnet）、`http://attic.nix.svc.cluster.local:8080`（集群内 CI）。`api-endpoint` 故意不设，见 secret 内注释。

## 产物生命周期

CI（`build-and-push.yaml`）用 `attic push "$ATTIC_CACHE"` 把 closure 推入 cache（cache 名见 Forgejo Actions secret `ATTIC_CACHE`）。

GC 是 `atticd` 内置的。`server.toml` 里：

```toml
[garbage-collection]
default-retention-period = "6 months"
```

未显式设置时 GC 间隔为 12 小时，默认 `monolithic` 模式会自动运行。

回收逻辑（`server/src/gc.rs`）：

1. 对每个 cache，删除 `created_at` 和 `last_accessed_at` 都早于保留期的 object；
2. 回收不再被任何 object 引用的 NAR；
3. 回收不再被任何 chunkref 引用的 chunk。

`last_accessed_at` 在读取（narinfo/NAR）时更新，所以仍在被拉取的闭包不会被删。保留期可以按 cache 覆盖（`attic cache configure --retention-period`，存放在数据库）；当前 cache `nix-fleet` 使用全局默认。

手动触发一次性 GC（在 attic Pod 内）：

```bash
kubectl -n nix exec deploy/attic -c app -- \
  env RUST_LOG=info atticd --mode garbage-collector-once --config /config/server.toml
```

`monolithic` 模式的 GC 日志默认不输出到容器日志；要看结果就用上面这条一次性命令。

## 现状与监控

- Store 占用约 45 GiB / 100 GiB（2026-09-30）。
- 集群约 2026-05 上线，还没有 object 触及 6 个月窗口，因此 GC 目前只回收 orphan NAR/chunk；预计 2026-11 之后才开始按窗口回收 object。
- 检查占用：

  ```bash
  kubectl -n nix exec deploy/attic -c app -- df -h /var/lib/attic/store
  kubectl -n nix exec deploy/attic -c app -- du -sh /var/lib/attic/store
  ```

## 决策与待办

- 观察第一个 6 个月窗口结束后 store 是否收敛。若不收敛或增长过快，缩短 `default-retention-period`（改 SOPS 里的 `server.toml`）或扩容 `attic-store`。
- 保留期基于「最近访问时间」，不保证某个闭包一定保留 6 个月。需要长期可替换的闭包要确保被定期访问/重新 push，或单独调高保留期。
- 客户端 `/nix/store` 的 GC 不在 Attic 范围内，见 [runner-maintenance.md](./runner-maintenance.md)。

## 相关

- Forgejo 侧产物（release asset、容器包、Actions artifacts）见 [forgejo-artifact-lifecycle.md](./forgejo-artifact-lifecycle.md)。
