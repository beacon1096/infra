# Forgejo runner 维护

三台 Harvester Nix 构建机各自一次只接收一个 Forgejo Actions 作业。工作流作业和 runner 的最长运行时间均为 12 小时。存储维护不能与运行中的作业重叠：垃圾回收可能删除仅由求值缓存保留的 derivation，而垃圾回收和存储优化都会产生足以让构建看似停滞的 Longhorn I/O。

## 轮换安排

每次只有一个 runner 进入维护状态，另外两个保持可用。

| Runner | 开始排空 | 存储维护 | 恢复运行 |
| --- | --- | --- | --- |
| `nixbuilder-01` | 周日和周三 15:00 | 周一和周四 03:15 | 周一和周四 04:25 |
| `nixbuilder-02` | 周一和周四 15:00 | 周二和周五 03:15 | 周二和周五 04:25 |
| `nixbuilder-03` | 周二和周五 15:00 | 周三和周六 03:15 | 周三和周六 04:25 |

所有时间均采用主机时区 `Asia/Shanghai`。周日没有存储维护时段。

## Harvester 节点分配

每台构建机都固定在不同的 Harvester 物理节点上：

| Runner | Harvester 节点 |
| --- | --- |
| `nixbuilder-01` | `mc4-01` |
| `nixbuilder-02` | `mc4-02` |
| `nixbuilder-03` | `mc5-01` |

这样可避免两个 I/O 密集型 Nix 构建在同一台虚拟机宿主机上争用资源。映射在 `terraform/harvester/variables.tf` 中声明；不要依赖 Harvester 默认的首选反亲和性，因为它并非强制性的节点分配约束。

固定节点有意以虚拟机级故障转移能力换取可预测的构建容量。如果某个 Harvester 节点故障或进入维护，其构建机将保持不可用，而不会迁移到另一台构建机所在的节点；另外两个 runner 仍可接收作业。维护期间可以手动实时迁移，暂时覆盖节点分配，但之后应恢复声明的映射。

Longhorn 为每台构建机的磁盘保留三个副本，每个存储节点各一个。迁移虚拟机会改变其计算节点位置和 Longhorn 卷前端，但不会重新均衡副本分布，也不会减少节点的存储预留量。

## 执行顺序与故障处理

1. 排空定时器写入 `/var/lib/nixbuilder-maintenance`，跨重启保留排空状态，防止系统激活或重启让 runner 提前恢复。首次部署时，激活脚本会将旧的 `/run/nixbuilder-maintenance` 标记迁到新路径。
2. runner 停止接收新作业，并最多等待 12 小时让当前作业完成。`KillMode=mixed` 最初只向 runner 发送 SIGTERM，因此作业子进程可在等待期间继续运行直至完成。在 `TimeoutStopSec=12h5m` 之后，systemd 可以强制停止剩余的进程组。维护在开始排空 12 小时 15 分钟后启动。
3. 03:15 时，只有标记存在且 runner 已完全停止，才会执行维护。否则跳过维护，以免影响仍在运行的构建。
4. `nix-collect-garbage --delete-older-than 7d` 和 `nix-store --optimise` 共用一小时的 systemd 超时。已在这些构建机上禁用每日自动垃圾回收和优化。
5. 04:25 时删除标记并启动 runner。恢复运行的定时器具有持久性，因此如果主机在 04:25 不可用，下次启动时仍会恢复运行。

如果作业经常接近 12 小时，请保留这一维护时段。消除长时间运行的作业后，应同步缩短工作流超时、runner 超时、停止服务超时和排空提前量；只改其中一项可能终止正在运行的作业，或使维护与作业重叠。

维护门控只覆盖此 runner 的作业，不协调手动构建或其他 Nix 守护进程客户端。工作流通过 `eval-cache = false` 禁用持久求值缓存。GC 选项 `--delete-older-than 7d` 会在回收前删除旧的 profile 代；它不保证未被根引用的存储路径能保留七天。

## 验证

修改时间安排后，对三台主机进行求值，并检查其定时器：

```bash
nix build \
  .#nixosConfigurations.nixbuilder-01.config.system.build.toplevel \
  .#nixosConfigurations.nixbuilder-02.config.system.build.toplevel \
  .#nixosConfigurations.nixbuilder-03.config.system.build.toplevel

systemctl list-timers 'nixbuilder-*'
systemctl show "gitea-runner-$(systemd-escape "$(hostname)").service" \
  -p KillMode -p TimeoutStopUSec
```

部署后，使用受控测试作业验证：排空会在当前作业完成的同时阻止获取新作业，维护标记会阻止 runner 启动，而当 runner 尚未完全停止时会跳过维护。Nix 构建成功只能验证配置，不能检验这些实际运行时行为。
