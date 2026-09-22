[中文](AGENTS.md) | [English](AGENTS_en.md)

你是一名经验丰富、务实的软件工程 AI agent。保持改动最小，并维护仓库的
公开/私有边界。

# 项目概览

这个公开 monorepo 包含 Beacon 的 NixOS 与 nix-darwin 机队配置、
Talos/Kubernetes/Flux 配置，以及基础设施清单。密钥由 SOPS 管理。

# 仓库边界

- SOPS 密文可以提交；明文凭据与解密输出则不行。
- 私有云主机定义与私有边缘/代理拓扑只属于 `infrastructure/infra-private`。
- 不要将私有仓库的文件、主机清单或服务拓扑加入本仓库——即使其凭据是加密的。
- Nix flake 保留在仓库根目录；不要把 `infra-private` 添加为子模块。

# 重要路径

- `flake.nix`：公开主机定义与包输出。
- `hosts/`、`modules/`、`packages/`：Nix 机队源码。
- `secrets/`：仅存放加密材料。
- `taichu/`、`wanxiang/`：集群配置与清单。
- `.forgejo/workflows/`：Forgejo Actions workflow 与发布门禁。

# 验证

命令从仓库根目录运行。

- 大范围求值：`nix flake show --all-systems`
- 定向 NixOS 构建：`nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
- macOS 构建：`nix build .#darwinConfigurations.beacon-mac-mini-m4.system`
- Shell 校验：`bash -n utils/<script>.sh`
- 格式化：可用时使用 `nix fmt`，否则对改动的 Nix 文件运行 `nixpkgs-fmt`。

Coder coding-agent 镜像使用单用户 Nix，且 `sandbox = false`。
在该运行时内，不要用 PR 控制的源码构建完整的 NixOS 或 nix-darwin 闭包。
本地使用求值与聚焦的非 Nix 测试，然后要求对应提交在 Forgejo CI 上的结果。
完整的定向构建仍需在沙箱化的 CI runner 或 builder 上完成。

不要提交生成的 `result*` 链接或本地凭据。发布前检查每个 diff 是否包含
私有主机数据。
