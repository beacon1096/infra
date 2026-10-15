# 观测约束的分批发布候选

`utils/plan-observed-rollout.mjs` 是生产发布前的离线、只读判定器。它只输出 `candidate-for-human-review` 或 `blocked`，且始终输出 `authorized: false`；不会访问 Forgejo、停止服务、合并、打标签、移动 `prod`、调用 Comin 或修改 n8n 审批链。

现有生产流程保持不变：`infra-private` 精确 SHA 的手动 `build-and-push.yaml` → n8n 人工审批 → 发布标签完整构建 → `infra-private/prod` 晋级 → Comin。本操作包只为获批维护窗生成精确批次和恢复材料，不能替代其中任何批准。

## v2 输入契约

从同一份 `infra-private` 候选 checkout 准备 plan 与 inventory。私有主机、端点和通道只保留在私有 inventory；公共 fixtures 使用仓库已有主机与路径，仅验证 fail-closed 行为。

plan 必须绑定：

- `infrastructure/infra-private`、diff base、候选 source commit 和已知良好 `prod` commit 的完整 SHA；
- 严格 RFC3339 UTC 求值时间，以及观测/恢复最大年龄；
- 规范的仓库相对文件路径；
- 每台主机的来源、种类、revision role 和观测时间；
- 每台主机的已知良好本地 generation、store path、持久 hold 能力、验证时间及独立通道；
- 单机 canary、后续批次、每批观察窗和固定停止条件。
- 新鲜的当前 `prod` 观测；若进入恢复解除阶段，还须成组提供向前恢复 source、新 promotion、`Source-Commit`、配置清单等价摘要及各自观测时间，不能部分填写。

inventory 的 `snapshot` 与候选 SHA 相同。`attestation` 记录 `nix-eval-and-human-review`、审阅者、时间、输入路径、diff base、`git diff --name-only <base>..<candidate>` 完整路径集合摘要及完整 scope 摘要。每条路径规则还记录候选 revision、导入闭包来源、`complete: true` 和消费者集合摘要。plan 少报或替换任何变更路径都会使摘要不匹配并阻断。

采集者在候选 checkout 中列出 `nixosConfigurations`，沿目标文件的 Nix `imports` 边遍历到所有 public 与 private overlay 消费者，并对每个消费者完成对应 flake configuration 求值。审阅者逐项核对候选 diff、导入闭包、主机集合、服务和风险域后，才写入消费者及 scope 摘要。摘要防止清单在 dry-run 后被静默缩减；它不是对错误清单的真实性证明，因此缺少生成记录或独立审阅时仍必须 `blocked`。

规则以 `match_kind: file|directory` 区分精确文件和以 `/` 结尾的目录，拒绝文件后缀、绝对路径、反斜杠、空段、`.` 与 `..`。运行态规则的 hosts/services 不得为空。`disko.nix`、存储、认证、网络和控制平面路径有独立安全分类，不能被更宽的 application 目录规则降级。

证据 kind/source 不能为空且每台主机唯一。记录必须匹配契约指定的 candidate 或 known-good SHA；缺失、重复、过期、未来、未知状态或来源/仓库/SHA 错配全部阻断。

## Dry-run

```console
nix shell nixpkgs#nodejs_24 --command node utils/plan-observed-rollout.mjs \
  --plan ./rollout-plan.json \
  --inventory ./private-release-impact-inventory.json \
  --output ./rollout-candidate.json
```

退出码 `0` 只表示材料可交现有人工发布审阅；退出码 `2` 表示停止。输出保留 inventory attestation、逐路径主机/服务、观测、每阶段期望 revision、held hosts 及本机恢复命令。

离线回归：

```console
nix shell nixpkgs#nodejs_24 --command node utils/test-observed-rollout.mjs
```

回归覆盖严格 schema、规范路径、存储风险、空影响、共享消费者完整性、证据来源/时间/revision、批次、持久 hold 前置、控制通道故障、本机 generation 和独立恢复。服务状态转移模型还覆盖 hold 安装失败、peer 重启、known-good activation、控制中断恢复及恢复后解除；隔离 Git 图同时验证旧 source 被发布祖先保护拒绝、向前恢复 source 被接受且生成新的 promotion SHA。它们基于固定版本源码语义，不是 systemd VM 或现场演练。

## 复用现有 Comin 的分批方式

固定 flake 中的 Comin revision 为 `3337c976e7733f68b99a1c00c713feb73495a946`，NixOS 单元为 `comin.service`，`Restart=always` 且由 `multi-user.target` 拉起；单独 `systemctl stop` 不能跨 activation 或重启保持。公共模块为此提供默认关闭的 `beacoworks.comin.rolloutHold.enable`。启用后单元带 `ConditionPathExists=!/var/lib/comin/rollout-hold`：root 创建持久 marker 后，systemd 在每次启动单元之前拒绝 Comin，marker 不存在时行为与原配置相同。

这是使用本包的硬前置，不是本 PR 的生产授权：先将只增加 condition、但尚无 marker 的模块作为单独获批发布部署到所有目标主机；逐台验证已知良好 `prod` revision、本地 recovery generation 和当前 generation 都包含上述精确 condition，且 marker 不存在、Comin active。然后才把该 revision 记录为 plan 的 `known_good_sha`，并通过候选 Nix 求值证明候选 source 仍启用同一 condition。旧 generation 或候选不含 condition、condition 未实读或 generation/store path 不匹配时，planner 必须 `blocked`，不得开始候选发布。

Comin 实际 checkout 的是 `prod` promotion commit，不是 infra-private source commit。plan 中 `candidate_sha`/`promotion_source_sha` 表示 source identity，`candidate_prod_sha` 表示 Comin 应报告的 promotion identity；必须由 promotion commit 的 `Source-Commit` 把两者连接。`current_prod_sha` 及其观测时间还必须与当前阶段一致：候选发布前为 known-good，候选晋级后为 candidate promotion，向前恢复后为 recovery promotion。所有主机动作的 `expected_revision`/`expected_prod_revision` 都只表示 promotion commit，并另列 `expected_source_revision`，不再混用。

本包不新增发布分支或绕开 n8n。获批执行时按 planner 输出完成：

1. 在任何变更前确认 `prod=known_good_sha`，记录每台主机的 `comin.service` 原状态、精确 unit condition、marker 不存在、`comin_deployment_info`、`/run/current-system` 和恢复 generation；任一缺失即停止。
2. 对每台非 canary 主机先执行 planner 的 `install-persistent-hold`，再 `stop-service`，最后 `verify-persistent-hold`。验证 marker 存在、condition 精确匹配、单元 inactive、store path/known-good revision 未变化。全部 hold 未验证前不进入发布审批；安装中途失败时 `prod` 尚未变化，保留已安装 marker，按记录逐台清理，禁止盲目继续。
3. canary 的 Comin 保持 active。继续使用原手动 `build-and-push.yaml` 和 n8n 人工批准；只有原发布流水线成功才允许 `prod` 晋级。晋级提交 SHA 通常不同于 candidate source SHA，因此立即读取新 `prod` 完整 SHA、核验其 `Source-Commit` 等于 candidate，并将三项 promotion evidence 和观测时间填回 plan 重跑 dry-run。在精确 promotion proof 通过前，canary 阶段只显示 `awaiting-exact-promotion-proof`，不得记为成功。
4. canary 的 `comin_deployment_info.commit_id` 必须等于精确 `candidate_prod_sha`，同时 promotion 的 `Source-Commit` 等于 `candidate_sha`；在完整观察窗内主机和服务证据保持健康，held peer 即使 activation/重启仍须 marker 存在、Comin inactive、store path 保持 known-good。
5. 达标后只对当前批次依次执行 `remove-persistent-hold`、`start-service`、`verify-promotion`，验证 promotion/source 两条身份链。未到批次的主机保留 marker，不得提前启动。全部批次成功后确认所有原 active 的 Comin 已恢复 active、均报告精确 promotion、marker 全部清除，再结束维护窗。

每项 marker、服务、原生产发布和验证动作都标记 `requires_existing_human_approval: true`。没有精确 promotion proof 时后续批次动作数组为空；fixture 只验证生成和状态转移，不代表现场已安装 hold 或部署。

marker/condition 消失、held Comin active、`prod`/promotion/source 漂移、任一证据缺失/异常、观察窗未完成或控制通道不可用都立即停止。Comin 指标因明确 hold 消失只能记为“已验证 inactive 的维护状态”，不能显示为健康；若没有同一主机的 marker、condition、单元状态和 store path 证据，则按缺失失败。

## 控制通道故障与恢复

每台主机必须提供 `local-console` 或 `out-of-band-console`，并证明不依赖 Forgejo、n8n、Comin 和生产网络。普通 SSH 或“重试 n8n”不能作为独立恢复。恢复记录必须把 host、known-good SHA、本地 generation 编号、store path、持久 hold condition、验证时间和命令绑定在一起；known-good generation 必须已包含该 condition。

控制通道失联时：

- 不启动下一批、不移除任何 marker、不尝试移动 `prod`；
- 从独立控制台依次创建 `/var/lib/comin/rollout-hold`、停止 Comin、运行 `<known-good-store>/bin/switch-to-configuration switch`。marker 必须在 stop 和 activation 之前就位，不能事后补停；
- known-good activation 仍由其 unit condition 拒绝 Comin。确认 marker/condition 存在、`/run/current-system` 等于记录的 known-good store path、业务服务恢复且 Comin inactive；
- 任一 generation 不含 condition 时停止，不执行 switch；使用另一个已验证 generation 或人工恢复材料，不能把该缺口留给运行中判断。

恢复解除分为两条互斥路径：

- `prod` 尚未变化：以新鲜 `current_prod_sha=known_good_sha` 证明候选从未晋级，才可使用 `cleanup_before_prod_change`，且仅对本次记录中已经创建 marker 的主机清理并恢复其原 active 状态；
- `prod` 已晋级：不得重发历史 source、reset 或 force-push `prod`。从 candidate source 创建经过审阅的向前恢复 source，保留发布链祖先关系；以 `nix-eval-and-reviewed-diff` 记录审阅者，并核对其 NixOS 配置清单与历史 known-good 配置清单的 SHA-256 一致。仍通过原手动发布、n8n 审批和 promotion 流程生成新的 recovery prod commit，再记录 recovery source、recovery prod、promotion `Source-Commit`、配置清单摘要及时间。只有完整、匹配且新鲜的证据使 `release_after_forward_recovery` 生成逐机移除 marker、启动 Comin 和核对新 promotion/source 的动作。

源码 tree 或配置清单相同不代表 promotion SHA、带 revision metadata 的 store path 或运行态完全相同；因此必须把恢复 source 和新 promotion 分别验收。恢复证据缺失、部分填写、错配、过期、来自未来，`current_prod_sha` 不符或控制通道失联时，解除动作保持为空，marker 保持。清理只针对精确 marker 路径，不删除目录或其它状态。

没有完整 attestation、真实现场 observation、原状态、独立通道或已验证本地 generation 时，输出必须保持 `blocked`。认证、网络、存储和控制平面变更继续单独审阅。
