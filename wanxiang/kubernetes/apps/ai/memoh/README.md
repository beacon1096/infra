# Memoh

此目录包含 Memoh、Connect-It 及其 PostgreSQL 服务的可复用 Kubernetes 清单。实例编排、访问入口和 SOPS Secret 由私有仓库提供。

部署前需要在 `ai` namespace 提供以下 Secret：

- `memoh-config`：`config.toml`、`admin-password` 和 `postgres-password`；
- `memoh-litellm-service-key`：`api-key`；
- `memoh-connect-it-config`：`database-url`、`secret-key`、`cookie-secret`、`admin-password`、`api-token` 和 `public-base-url`。

当前 Memoh 镜像版本为 `0.20.0`。Connect-It 与 Memoh 共用 `memoh` 数据库，并在独立的 `connect_it` schema 中自行迁移。

## Desktop / WebRTC 媒体路径

Workspace Desktop（Web UI 的 Desktop 面板）的媒体由 `memoh-server` 内的 Pion WebRTC endpoint 提供，不是 GStreamer `webrtcbin`。默认行为是每会话随机 UDP 端口，并把 SDP candidate 的 IP 改写为请求 Host（`candidate_host`）。本目录清单既没有固定 UDP 端口，也没有把该端口作为 UDP Service 暴露，因此经 Tailscale Operator 入口访问时 candidate 指向的地址不可达，桌面面板必然 ICE failed。

`0.20.0` 已支持固定单 UDP 端口与显式 NAT 地址（上游 Docker Compose 已按此部署），K8s 侧只需补齐部署语义：

- `MEMOH_DISPLAY_WEBRTC_UDP_PORT=30000`：所有 peer 共用一个进程级 UDP mux 端口；
- `MEMOH_DISPLAY_WEBRTC_NAT_IPS=<memoh-rtc 的 tailnet IP>`：显式覆盖推导出的 candidate 地址，必须是 IP（主机名会导致启动失败）；实际取值由私有仓库提供；
- 新增一个带 `tailscale.com/expose` 的 UDP Service（如 `memoh-rtc-tailscale`，`protocol: UDP`，端口 `30000`），Tailscale Operator 以 L3 方式 DNAT 到 Service ClusterIP。

媒体本身还要过 tailnet 的 1280 MTU：GStreamer RTP payloader 默认 `mtu=1400`，超出的包在这条路径上会静默丢失（客户端表现为 ~45% 丢包、持续 PLI/NACK、永远解不出帧）。`gst-wrapper.yaml` 用包装脚本把 H.264/VP8 payloader 限制到 `mtu=1200`，通过 `MEMOH_GSTREAMER_LAUNCH` 接入。

客户端侧还有一处：sing-box 把回包注入 tun0，而 NixOS 的 `nixos-fw-rpfilter` 在策略路由查 table 2022 之前就把它们丢了（TCP 因 `auto_redirect` 走本地监听不受影响，只有 UDP/WebRTC 受害）。修复在私有仓 `modules/nixos/sing-box.nix`（对 `-i tun0` 提前 ACCEPT）。

Tailscale Operator 的 `tailscale.com/expose` 支持 TCP/UDP L3 Service，当前 `memoh-tailscale` 只有 TCP 8082 是因为 Service 未声明 UDP，不是 Operator 的限制。WebRTC 媒体不要经过 Cloudflare：`memoh.beaco.works` 继续只作为 Web/API 入口，Desktop 暂时面向已加入 tailnet 的客户端。TURN 是后续“Desktop 公网化”的独立上游需求。

问题定位、源码依据（PR #1104、v0.20.0 `internal/display/service.go`）与验证步骤见 https://chatgpt.com/share/6abcc484-e924-83e9-95b0-e55074cf51ee 。
