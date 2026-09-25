# CI/CD 与机群交付

这里记录跨仓库的交付控制流程。集群实现细节和故障恢复步骤仍放在 `wanxiang/docs`；基础设施运维文档见 [`docs/infra-ops`](https://github.com/beacon1096/infra/tree/main/docs/infra-ops)。

- [仓库与分支提交流转](repository-flow.md)：两个仓的 `main`、`prod` 分支及 PR 和自动发布入口。
- [生产发布与 Nix 部署](production-release-and-rollout.md)：公开/私有仓边界、发布标签、`prod` 分支与 Comin。
- [Renovate 与 Multica 合并门禁](renovate-multica-gate.md)：依赖更新、审查凭据、信任边界和受保护分支合并。
- [Forgejo 服务账号](forgejo-service-accounts.md)：自动化身份与凭据隔离。
- [Agent 的 Nix 构建信任边界](agent-nix-build-trust.md)：本地 `sandbox = false`、CI 验证证据与远程构建机规划。

相关运维手册：

- [Forgejo Actions runner](../../../../wanxiang/docs/operations/forgejo-runner.md)
- [n8n 恢复](../../../../wanxiang/docs/operations/n8n-restore.md)
- [Attic 恢复](../../../../wanxiang/docs/operations/attic-restore.md)
- [Flux 与 Helm 恢复](../../../../wanxiang/docs/operations/flux-helm-recovery.md)
