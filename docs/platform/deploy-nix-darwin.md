# nix-darwin 远程部署

部署脚本为仓库根目录的 [`utils/deploy-nix-darwin.sh`](../../utils/deploy-nix-darwin.sh)。它通过 SSH 上传当前配置，按需安装 Homebrew、Nix daemon 和 nix-darwin，然后激活指定的 flake 主机。部署流程与 Forgejo runner、审批和 `prod` 晋升的关系见 [CI/CD 与机群交付](../agentic/workflow/infra-ops/README.md)；目前没有可用的 macOS runner，nix-darwin 不在自动构建矩阵中。

从公开或私有仓库根目录运行；`--source-dir` 默认取脚本所在仓库的根目录。若需部署私有配置，请显式指定私有仓脚本和源码目录，避免误把公开配置部署到目标机。

```bash
utils/deploy-nix-darwin.sh \
  --host <macOS-SSH-主机> \
  --user <登录用户> \
  --flake-host beacon-mac-mini-m4
```

`--flake-host` 对应 `flake.nix` 中的 `darwinConfigurations` 键。可选 `--port`、`--remote-dir`、`--source-dir`、`--proxy`、`--cn`、`--local-build`；完整参数以脚本 `--help` 为准。默认远端目录为 `.config/nix-darwin`，脚本支持密码或密钥 SSH 登录并复用连接；远端安装 Nix 可能要求 sudo。`--local-build` 会在本机先构建，再复制闭包并在远端激活，不应在不兼容的平台上使用。

脚本末尾读取远端 SSH 主机公钥并转换为 age 收件人，便于后续配置 sops；不会从主机导出私钥。首次接入前应独立核对 SSH 主机密钥。当前脚本默认关闭严格主机密钥检查，`--no-strict-host-key-check` 也保持这一行为；这不是主机身份验证已完成的保证。
