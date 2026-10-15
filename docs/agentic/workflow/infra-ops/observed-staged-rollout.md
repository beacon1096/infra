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
- 每台主机的已知良好本地 generation、store path、验证时间及独立通道；
- 单机 canary、后续批次、每批观察窗和固定停止条件。

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

回归覆盖严格 schema、规范路径、存储风险、空影响、共享消费者完整性、证据来源/时间/revision、批次、控制通道故障、本机 generation 和独立恢复。

## 复用现有 Comin 的分批方式

固定 flake 中的 Comin revision 为 `3337c976e7733f68b99a1c00c713feb73495a946`，NixOS 单元为 `comin.service`，`Restart=always`；运维发出的 `systemctl stop comin.service` 会停止本次运行，但主机重启会再次按声明配置启动。Comin 暴露 `comin_deployment_info{commit_id,status}`，可与 `/run/current-system` 的 store path 一起确认实际 revision。

本包不新增发布分支或绕开 n8n。获批执行时按 planner 输出完成：

1. 在任何变更前确认 `prod=known_good_sha`，记录每台主机的 `comin.service` 原状态、`comin_deployment_info`、`/run/current-system` 和恢复 generation；任一缺失即停止。
2. 通过既有管理通道在所有非 canary 主机执行 `sudo systemctl stop comin.service`。逐台确认单元为 `inactive`、`/run/current-system` 未变化；不能确认全部 hold 时，不进入发布审批。
3. canary 的 Comin 保持 active。继续使用原手动 `build-and-push.yaml` 和 n8n 人工批准；只有原发布流水线成功才允许 `prod` 晋级。晋级提交 SHA 通常不同于 candidate source SHA，因此立即读取新 `prod` 完整 SHA、核验其 `Source-Commit` 等于 candidate，并将三项 promotion evidence 和观测时间填回 plan 重跑 dry-run。在精确 promotion proof 通过前，canary 阶段只显示 `awaiting-exact-promotion-proof`，不得记为成功。
4. canary 必须报告精确 candidate SHA，并在 plan 规定的完整观察窗内保持主机和服务证据健康；held 主机须保持原 store path。达标后，下一批才逐台执行 `sudo systemctl start comin.service` 并验证精确 candidate；未到批次的主机继续 inactive/known-good。
5. 全部批次成功后确认所有原 active 的 Comin 单元已恢复 active、主机均为 candidate，且无临时 hold，再结束维护窗。

每项 `stop-service`、原生产发布及 `start-service` 都在输出中标记 `requires_existing_human_approval: true`。fixture 只模拟 revision 选择：pre-release 阶段全部是 known-good `prod` commit；发布后仅 canary 对应经过 `Source-Commit` 核验的新 promotion commit；后续仅已启动批次对应该 promotion commit。它不代表现场已经 hold 或部署。

主机重启、单元自行恢复 active、`prod`/candidate 漂移、任一证据缺失/异常、观察窗未完成或控制通道不可用都立即停止。Comin 指标因明确 hold 消失只能记为“已验证 inactive 的维护状态”，不能显示为健康；若没有同一主机的单元状态和 store path 证据，则按缺失失败。

## 控制通道故障与恢复

每台主机必须提供 `local-console` 或 `out-of-band-console`，并证明不依赖 Forgejo、n8n、Comin 和生产网络。普通 SSH 或“重试 n8n”不能作为独立恢复。恢复记录必须把 host、known-good SHA、本地 generation 编号、store path、验证时间和命令绑定在一起。

控制通道失联时：

- 不启动下一批，不解除任何 hold，不尝试移动 `prod`；
- held 主机保持 known-good；若重启导致 Comin 恢复 active，立即按失败处理；
- 已进入 candidate 的主机从其独立控制台执行记录中的两个动作：先 `/run/current-system/sw/bin/systemctl stop comin.service`，再运行 `<known-good-store>/bin/switch-to-configuration switch`；
- 确认 `/run/current-system` 等于记录的 known-good store path、主机服务恢复且 Comin 仍 inactive。

控制通道恢复后，按既有发布流程把经过审阅的 known-good revision 重新发布到 `prod`。确认 `prod` 和各主机恢复后，才逐台恢复原 Comin active 状态。不要直接移动 `prod`，也不要在 candidate 仍位于 `prod` 时重新启动已回滚主机的 Comin。

没有完整 attestation、真实现场 observation、原状态、独立通道或已验证本地 generation 时，输出必须保持 `blocked`。认证、网络、存储和控制平面变更继续单独审阅。
