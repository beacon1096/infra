# CI/CD and fleet delivery

This directory describes the repository-wide delivery control plane. Cluster
implementation details and recovery procedures remain in `wanxiang/docs`.

- [Production release and Nix rollout](production-release-and-rollout.md) —
  the public/private boundary, release tags, `prod`, and Comin.
- [Renovate and Multica merge gate](renovate-multica-gate.md) — dependency
  updates, review capabilities, trust boundaries, and protected merging.
- [Forgejo service accounts](forgejo-service-accounts.md) — automation
  identities and credential separation.
- [Forgejo runner maintenance](runner-maintenance.md) — builder rotation and
  Nix store maintenance.

Related operational runbooks:

- [Forgejo Actions runner](../../wanxiang/docs/operations/forgejo-runner.md)
- [n8n restore](../../wanxiang/docs/operations/n8n-restore.md)
- [Attic restore](../../wanxiang/docs/operations/attic-restore.md)
- [Flux and Helm recovery](../../wanxiang/docs/operations/flux-helm-recovery.md)

