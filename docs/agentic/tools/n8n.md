# n8n 自动化

已在 [Home Manager MCP 配置](../../../modules/home/mcp.nix)中注册为远程 MCP，凭据由运行环境注入；Kubernetes 中部署了 [n8n 服务](../../../wanxiang/kubernetes/apps/development/n8n/app/helmrelease.yaml)。具体可执行哪些工作流取决于 n8n 侧配置；MCP 接入不代表针对某项操作的受限工作流已经实现。

Home Manager 配置面向 Claude Code、OpenCode、VS Code 和 Cursor；[Codex 的集成开关](../../../modules/home/coding-agent.nix)仍被注释。2026-09-24 本机 `codex mcp list` 显示没有配置 MCP 服务器，因此不能据此认定当前 Codex 会话可直接调用 n8n。核查方法见 [Codex 官方说明](https://developers.openai.com/learn/docs-mcp)。
