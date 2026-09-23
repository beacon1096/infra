# SearXNG 搜索

[Kubernetes 中部署](../../../wanxiang/kubernetes/apps/ai/searxng/app/helmrelease.yaml)了搜索服务。Pi 的 `web_search` 通过 HTTP API 调用它，并配置了网页抓取、搜索结果内容获取及 Tavily 回退；这**不是 SearXNG MCP**。

服务部署和 Pi 工具配置不代表当前 Codex 会话也接入了 SearXNG。
