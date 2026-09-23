# Paseo Daemon

Paseo 承接个人设备和临时工作区里的 Copilot 会话；Web UI、移动端、Desktop 或 CLI 是客户端，daemon 负责在所在机器启动和管理 agent。这里记录仓库声明，不把某台机器的实际在线状态当作已核验事实。

## 当前配置

- 两仓的 `modules/nixos/paseo.nix` 均导入上游 NixOS 模块。公开仓固定 Paseo `v0.3.1` 的 NPM 依赖哈希；私有仓用 `lib.mkForce` 替换为带补丁的包。
- `msi-claw` 明确启用 daemon，以 `beacon` 用户运行，监听 `0.0.0.0`，不开通全局防火墙端口，只允许 Tailscale 接口的 TCP 6767；同时配置自建 relay。主机名白名单包含公开域名和 Tailnet 域名。声明见 `hosts/personal/msi-claw/configuration.nix`。
- `coding-agent-oci` 在 Coder 工作区有 Tailscale 凭据时启动 userspace `tailscaled` 和监听本地回环地址的 `paseo-server --no-relay`，健康检查后由 Tailscale Serve 转发 6767。这个路径是直连 Tailnet，不经过自建 relay；声明见 `flake.nix` 的镜像入口脚本。私有仓也保留对应入口，尚未统一到公开模块。
- NixOS 模块设置 `systemd.services.paseo.restartIfChanged = false`：由 Paseo 管理的 agent 发起 NixOS 切换时，服务不应在激活中途重启。包升级或需要进程重读的配置变更，必须另行安排 daemon 重启。

## 下游补丁

Pi RPC 曾把 `agent_end` 误认为整个回合已结束；此时新输入可能被拒绝为 `Agent is already processing`，后台完成唤醒和取消也存在竞态。修复思路是缓存 `agent_end` 消息，等 `agent_settled` 再完成回合；后续输入走 `followUp`，中断前清空排队消息，并延长 abort 确认窗口。问题和验证见 [Pi 调查记录](../../harness/research.md#paseo-rpc-兼容修正2026-09-15)。

实现和回归测试补丁分别存放在公开仓 [`lib/paseo/pi-rpc-lifecycle.patch`](../../../../lib/paseo/pi-rpc-lifecycle.patch) 和 [`lib/paseo/pi-rpc-lifecycle-tests.patch`](../../../../lib/paseo/pi-rpc-lifecycle-tests.patch)。私有仓目前仍使用相同内容的本地副本构建 daemon、Desktop 和测试；这不是上游 `v0.3.1` 的原生行为。

## 待核实的访问边界

仓库未声明 `PASEO_PASSWORD` 或等效的密码设置；daemon 的持久状态可能在仓库外设置了密码，目前未核验。尤其 `msi-claw` 绑定 `0.0.0.0`，不能仅凭 `openFirewall = false` 推断所有网络接口均不可达。上游[安全说明](https://github.com/getpaseo/paseo/blob/main/public-docs/security.md)要求直连暴露时设置密码并审查监听地址。核实前不要把该端点当作已完成鉴权的公开服务；此处只记录风险，不擅自修改网络配置。
