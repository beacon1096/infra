# Paseo Relay

万象集群已有自建 relay 声明：`wanxiang/kubernetes/apps/development/paseo-relay/` 部署单副本 `ghcr.io/zenghongtu/paseo-relay:latest`，Service 监听 8411，由外部 Envoy Gateway 将 `paseo.${SECRET_DOMAIN}` 的 HTTPS 请求转发到它。容器有 `/health` 就绪与存活检查；镜像仍用可变的 `latest` 标签，没有固定摘要。

`msi-claw` 的 `services.paseo.relay` 使用远端模式，连接 `paseo.beaco.works:443`，并设置 TLS 与对外 TLS；`PASEO_RELAY_PUBLIC_ENDPOINT` 指向同一地址。Coder 的 `coding-agent-oci` 则显式 `--no-relay`，只经 Tailscale Serve 暴露本地 daemon。不要把这两种连接方式混为一谈。

上游 [Paseo 安全文档](https://github.com/getpaseo/paseo/blob/main/public-docs/security.md)将 relay 设计为端到端加密的转发节点，配对链接包含 daemon 的公钥；relay 本身不应取得会话内容。但当前部署使用第三方 relay 镜像，尚未在仓库中记录与所固定 Paseo 版本及移动端的互通验收。部署清单只能证明“已声明自建 relay”，不能证明手机配对、重连和断线恢复均已测试。后续见 [待办](TODO.md)。
