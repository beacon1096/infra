# Terraform / OpenTofu 运行手册

本仓的 OpenTofu/Terraform 栈位于 `terraform/`，用于表达 Flux/Comin 覆盖不到的
云侧资源（Cloudflare DNS、UniFi、Authentik 等）。state 不入 Git，按栈存放在集群的
`terraform-state` 命名空间（`backend "kubernetes"`）。

## 栈与 state

| 栈 | 作用 | state secret（`terraform-state`）|
| --- | --- | --- |
| `terraform/cloudflare-bootstrap` | 创建 scoped `terraform-dns` 账号 token | `tfstate-default-cloudflare-bootstrap`（当前缺失）|
| `terraform/cloudflare-dns` | 两个 zone 的 DNS 记录（邮件、边缘等） | `tfstate-default-cloudflare-dns` |
| `terraform/unifi-wanxiang` | UDM-Pro 网络与静态路由 | `tfstate-default-unifi-wanxiang` |
| `terraform/authentik-wanxiang` | Authentik 应用/OIDC | `tfstate-default-authentik-wanxiang` |
| `terraform/harvester` | Harvester | 见该栈 |
| `terraform/routeros-rb5009`、`stalwart-shuttle`、`litellm-wanxiang` | 各自用途 | 同名 secret |

state 归属集群以运行时的 `KUBECONFIG` 为准（ wanxiang `172.16.87.1:6443` 或
Harvester）；不同栈可能不同。

## 运行方式

统一通过各栈目录下的 `run.sh`，不要手工拼 `tofu`。脚本会设置 `KUBE_CONFIG_PATH`，
并在 `init` 时用 `-backend-config=config_path=$KUBECONFIG` 固定后端——在 Pod 里
in-cluster ServiceAccount 会覆盖 `KUBECONFIG`，这一步是必须的。

```sh
export KUBECONFIG=/run/coder-infra/kubeconfig   # 指向 state 所在集群
terraform/cloudflare-dns/run.sh init -reconfigure
terraform/cloudflare-dns/run.sh plan -input=false -out=tfplan
# 人工审查 tfplan：确认仅有意料中的新增/修改，无 destroy/replace
terraform/cloudflare-dns/run.sh apply tfplan
```

- 工具：`tofu`、`kubectl`、`sops`、`jq`。镜像未预置 `tofu` 时用
  `nix-shell -p opentofu`（预置见后续改动）。
- `cloudflare-dns` 的 token 优先取 `CLOUDFLARE_API_TOKEN`，否则从
  `secrets/shared/cloudflare.yaml` 的 `terraform_dns_token` 解密。
- `cloudflare-bootstrap` 需 `CLOUDFLARE_BOOTSTRAP_API_TOKEN`（账号级 token 管理
  权限，一次性；刻意不入 SOPS）。
- 需要访问 vault/provider 凭据的栈，按其 `run.sh` 从 SOPS 解密到进程环境，
  不要把解密结果写入 state 或磁盘。

## 凭据与边界

- `cloudflare-dns` 使用**专用 scoped token**（仅这两个 zone 的 DNS 编辑），密文入
  SOPS；不要复用 `edge-caddy` 的 ACME token。
- Cloudflare token 的值只在创建时可见；import 只能恢复 token ID、不能恢复值。
  值一旦丢失，只能轮换重建。
- 明文 token、state、`.terraform/` 不得入 Git。

## 审批与回滚

- `apply` 属网络核心/DNS 变更，需针对目标栈与 plan 的明确批准；出现新增删除或
  替换时重新申请。
- apply 必须与已审阅 plan 实质一致。回滚优先改记录/`proxied` 而非删资源；多数
  资源带 `prevent_destroy`，删除用 `removed` 块。

## 已知缺口（BEACO-185）

- `cloudflare-bootstrap` state 缺失：需重建或导入，并把 scoped token 落 SOPS，
  避免继续借用其他 token。
- 运行环境（infra-maintainer）需要 `tofu`（预置或 `nix-shell -p opentofu`）。
