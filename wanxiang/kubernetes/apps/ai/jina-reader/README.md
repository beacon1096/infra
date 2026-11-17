# Jina Reader

提供固定镜像的非 root Reader、ClusterIP HTTP/1.1 8081 与仅选择 Reader 的默认拒绝 NetworkPolicy。公共 apps 根只接入一个 `suspend: true` 的工作负载协调入口；合并此清单不会启动 Reader。

先经批准安装并核对实例网络策略，再通过独立审批的 Git 修订解除暂停。不要关闭 Chrome sandbox、提权或放开网络来绕过启动失败，也不要把暂停协调当作停止已有 Pod。

这仍是未运行的候选清单：镜像拉取、只读目录、非特权 Chrome sandbox、策略数据面、资源与超时都需实际验收。`/ping` 就绪不证明浏览器抓取或 Memoh Fetch 成功；接入 Fetch 需另行批准，并从 Memoh server 发起真实工具调用验证。

上游日志可能记录 URL/query/选项，未确认全局并发限制；部分 curl 抓取路径不校验源站 TLS 证书。首轮仅受控串行、无敏感目标；常态启用前须审阅这些边界。
