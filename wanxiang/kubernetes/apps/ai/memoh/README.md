# Memoh

此目录包含 Memoh、Connect-It 及其 PostgreSQL 服务的可复用 Kubernetes 清单。实例编排、访问入口和 SOPS Secret 由私有仓库提供。

部署前需要在 `ai` namespace 提供以下 Secret：

- `memoh-config`：`config.toml`、`admin-password` 和 `postgres-password`；
- `memoh-litellm-service-key`：`api-key`；
- `memoh-connect-it-config`：`database-url`、`secret-key`、`cookie-secret`、`admin-password`、`api-token` 和 `public-base-url`。

当前 Memoh 镜像版本为 `0.20.0`。Connect-It 与 Memoh 共用 `memoh` 数据库，并在独立的 `connect_it` schema 中自行迁移。
