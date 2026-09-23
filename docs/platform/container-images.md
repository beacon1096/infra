# NixOS 容器镜像

私有仓 `flake.nix` 中的 `k8s-sing-box-image` / `k8s-sing-box-oci` 是将 NixOS 模块复用于 Kubernetes 的历史实例。公开仓也提供若干 edge OCI 输出；它们各自使用 `lib/edge-*` 构建逻辑，不应误认为都按本页的 systemd-in-container 方案启动。

## 构建与启动方式

该实例组合 sing-box、sops-nix 和 NixOS 容器配置，容器入口为 `/init`。启动后 systemd 执行 NixOS activation；sops-nix 从运行时挂载的 age 私钥解密配置，随后启动服务。私钥不进入镜像或 Nix store。日志通过 `services.journald.console = "/dev/console"` 输出，可由容器日志收集。

私有仓有两种不同输出，均需在 x86_64-linux 上构建或使用相应远端 builder：

```bash
nix build .#k8s-sing-box-image
# 结果是 result/tarball/nixos-system-x86_64-linux.tar.xz，供 docker import 等工具使用

nix build .#k8s-sing-box-oci
# 结果是 dockerTools 生成的 OCI 镜像归档，供 docker load / 容器运行时导入
```

`k8s-sing-box-image` 通过 NixOS toplevel 与闭包手工生成 rootfs tarball；`k8s-sing-box-oci` 再把它封装为可加载的镜像。不要将前者的 tarball 直接当成后者的 `docker load` 输入。CI 构建与推送目标是 `k8s-sing-box-oci`，声明在私有仓 `.forgejo/workflows/build-and-push.yaml`；镜像仓库地址、认证和部署清单以实际环境配置为准，不在这里写入凭据。

## 运行边界

- 容器启动时需要挂载只读 Kubernetes Secret，提供 `/var/lib/sops-nix/age.key`；NixOS 声明把 `sops.age.keyFile` 指向此路径。不要在构建阶段复制私钥或将其写入镜像层。
- sing-box 需要 TUN 时，容器还需相应网络权限（例如 `NET_ADMIN`）与设备访问；是否使用特权容器应由实际部署清单决定，不能从构建结果推断。
- 该目标启用私有仓的 `k8sTransparentProxy` 分支。它源自已放弃的 Talos/Cilium egress-gateway 方案，虽然构建目标和 CI 仍存在，不应把它描述为当前在集群中运行的生产网关。清理背景见 [MeshVPN 设计记录](mesh-vpn.md)。

新增镜像时，应先判断需要完整 NixOS/systemd 容器，还是只需 `lib/edge-*` 的较小服务镜像；仅在确需复用 activation、服务单元和 sops-nix 运行时解密时选择前者。
