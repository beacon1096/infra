环境说明：

- 这台机器是 NixOS，当前工作区 `/etc/nixos` 是系统 flake。
- 优先使用声明式 Nix 配置变更，避免临时全局安装。
- 一次性工具优先用 `nix-shell -p <package> --run '<command>'`，也可以按需使用 `nix shell nixpkgs#<package>`。
- `gh` 命令行已安装，可用于 GitHub issue、PR、release 和仓库查询。
- `nixpkgs-unstable` 可通过 flake input `inputs.nixpkgs-unstable` 使用；Home Manager 模块里已有 `pkgsUnstable`。
- 在当前环境里避免用通用 MCP fetch 读取网页；优先使用 OpenCode WebFetch、Tavily/search MCP 工具，或遵循 `web_search` skill 的选路规则。
