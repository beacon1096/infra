[中文](README.md) | [English](README_en.md)

# Beacoworks 基础设施

这是托管在 [Forgejo](https://forgejo.beaco.works/infrastructure/infra) 上的公开、权威的基础设施 monorepo。
[GitHub](https://github.com/beacon1096/infra) 是 `main` 分支的单向展示镜像。
在 Forgejo 上修改并运行 CI；GitHub Actions 已禁用。
生产审批与发布保留在 Forgejo 的 `infra-private` 中。

## 仓库结构

- `flake.nix`、`hosts/`、`modules/`、`packages/`、`secrets/`：公开的 NixOS 与
  nix-darwin 机队配置。
- `taichu/`：Harvester/RKE2 环境清单。
- `wanxiang/`：Talos、Kubernetes 与 Flux 配置。
- `kubernetes/flux/`：仓库级 Flux 入口。

Nix flake 保留在仓库根目录，使现有的 rebuild 与 Comin 流程只需更换仓库 URL。
迁移期间，现有 Attic 缓存与 OCI 包名继续沿用 `nix-fleet` 名称，以免破坏消费方。

## 公开与私有边界

可以提交 SOPS 加密的密钥；明文凭据、解密输出、kubeconfig、Talos 配置、
age 密钥与本地运行时状态则不行。

根级 Nix 密钥使用根目录的 `.sops.yaml`。Wanxiang 的 SOPS 命令从 `wanxiang/`
运行，或显式传入 `--config wanxiang/.sops.yaml`，使集群密钥保留各自的接收人集合。

在每个 clone 中启用仓库的暂存内容检查：

```bash
git config --local core.hooksPath .githooks
```

该 hook 通过 Nix 提供 Python 与 PyYAML。它检查暂存的 Git 内容中是否有私钥、
本地凭据文件，以及未加密的受保护 YAML/JSON 值（包括 Kubernetes Secrets）。
受支持的示例值与模板值可以放行；仅有 SOPS 元数据并不豁免明文字段。
诊断信息只显示文件位置，不显示凭据值。这是一项针对性检查，而非覆盖所有
token 格式的通用检测器，也不构成有效加密的证明。

`Check Secrets` workflow 在推送与 pull request 时运行回归测试并扫描检出的
提交。在本地运行相同的检查：

```bash
nix-shell -p python3Packages.pyyaml --run 'python3 utils/test-check-secrets.py'
nix-shell -p python3Packages.pyyaml --run 'python3 utils/check-secrets.py'
```

扫描器默认检查 `HEAD`；使用 `--staged` 检查尚未提交的暂存变更。
CI 在上传后才检测已提交的问题，因此不能替代本地 hook，也不能替代
对 `.sops.yaml` 中接收人变更的评审。

私有云主机定义与私有边缘/代理拓扑保留在独立的
`infrastructure/infra-private` 仓库中。它不是本仓库的子模块。
公开主机基线可以导出为 NixOS 模块供私有 overlay 使用，但私有行为及其
生产输出只在私有仓库中组装与发布。

## CI/CD 与生产交付

`infra/main` 是公开集成分支。`infra-private` 固定已评审的公开版本，
并负责生产审批、发布 tag、`prod` 晋级与 Comin 滚动发布。
完整的发布流程、依赖评审门禁、服务账号与 runner 维护，
请先阅读 [CI/CD 文档](docs/ci-cd/README.md)。
