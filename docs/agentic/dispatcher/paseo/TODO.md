# Paseo 自有部署待核实

- [WIP] 语音输入（ASR）及语音模式的 TTS：尚未决定算力部署位置与后端。上游提供本地或 OpenAI 兼容语音端点的方案，但仓库尚无 Paseo 语音配置；采用前须核对当前固定的上游版本是否支持所选方案（公开仓仍在 `v0.3.1`，私有仓已到 `v0.9.2`）。[上游语音说明](https://github.com/getpaseo/paseo/blob/main/public-docs/voice.md)
- [WIP] 核实 `msi-claw` daemon 的实际监听范围、持久密码与直连访问控制；Nix 声明中没有密码设置。确认前不扩大防火墙或网关暴露范围。
- [WIP] 自建 relay 镜像固定版本/摘要，并做移动端配对、断线重连与端到端加密链路验收；当前只是单副本、`latest` 标签的部署声明。
- [WIP] 私有仓升级到 `v0.9.2` 后已删除 Pi RPC 生命周期补丁及其回归测试：上游自己实现了 `agent_settled`、`clearQueue()` 先于 `abort`，旧补丁六个 hunk 有四个不再套用。仍需实测中断与后台完成唤醒的行为，确认上游实现覆盖了原补丁保护的场景。
- [WIP] Coder 工作区的 Tailnet 直连与 `msi-claw` 的 relay 连接分别完成客户端实测，记录 Web UI、Desktop、移动端可用路径。当前配置并不表示这些客户端均已验收。
