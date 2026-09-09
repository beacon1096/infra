# nix-darwin 远程部署脚本


> 另见：`docs/forgejo-ci.md`，其中定义了 Forgejo runner + Attic 二进制缓存流程，以及可选的 `main` → `prod` 人工晋升路径。
> 当前 CI 工作流仅构建 Linux Nix 目标；nix-darwin 目标已暂时从自动构建矩阵中移除，因为目前没有可用的 macOS runner。

新增脚本：`scripts/deploy-nix-darwin.sh`

用途：首次通过**密码 SSH 登录**远端 macOS，随后自动完成：
- 上传本地当前目录下的 nix-darwin 配置
- 安装 Homebrew（若未安装）
- 安装 Nix（若未安装）
- 安装 nix-darwin（若未安装）
- 应用 flake 配置

## 用法

在仓库根目录执行：

```bash
chmod +x scripts/deploy-nix-darwin.sh

./scripts/deploy-nix-darwin.sh \
  --host 192.168.1.20 \
  --user beacon \
  --flake-host beacon-mac-mini-m4
```

`--flake-host` 对应 `flake.nix` 中 `darwinConfigurations` 的键名，例如：
- `beacon-mac-mini-m4`
- `clerk`
- `clerk-technician`

## 常用参数

- `--remote-dir`：远端配置目录（默认 `~/nixconf-darwin`）
- `--source-dir`：本地上传目录（默认当前目录）
- `--port`：SSH 端口（默认 `22`）
- `--no-strict-host-key-check`：首次接入临时跳过主机密钥校验

## 说明

- 脚本使用 SSH 连接复用（ControlMaster），一般只需要输入一次远端密码。
- 远端安装 Nix（daemon 模式）可能会触发 sudo 提示，按终端提示输入即可。