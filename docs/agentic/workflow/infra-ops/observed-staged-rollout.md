# 观测约束的分批发布候选

`utils/plan-observed-rollout.mjs` 是生产发布前的离线、只读判定器。它只把经过完整校验的输入标记为 `candidate-for-human-review`；输出始终包含 `authorized: false`，不会合并、打标签、移动 `prod`、调用 Comin 或修改现有 n8n 审批链。

现有生产流程仍是 `infra-private` 精确 SHA 的手动 `build-and-push.yaml` → n8n 人工审批 → 发布标签完整构建 → `infra-private/prod` 晋级 → Comin。此工具不能替代其中任何一步，也不能为合并或部署授权。

## 输入准备

从同一份 `infra-private` 候选 checkout 生成两份 JSON：

1. plan：仓库名、候选与已知良好 40 位 SHA、求值时间、精确变更路径、观测记录、批次和停止条件。
2. inventory snapshot：相同仓库/SHA、生成时间、实际主机、必需观测契约、独立恢复方法，以及路径到主机/服务/风险域的映射。

私有主机、端点和恢复通道只进入私有仓的 inventory，不回填到公共仓。公共 fixtures 使用仓库中已有的主机与路径名称，仅用于证明判定行为，不能作为现场 inventory。

inventory 必须从精确 checkout 的 flake 输出、主机模块导入关系和私有 overlay 生成并审阅。共享模块的规则必须列出每个实际消费者并设置 `shared: true`；判定器拒绝把共享规则压缩成单主机影响。没有匹配规则的路径一律阻断。

每个受影响主机的 evidence 必须同时匹配：

- inventory 规定的来源和证据种类；
- `infrastructure/infra-private` 与候选 SHA；
- 明确 `healthy` 状态；
- 不晚于允许的未来时钟偏差，且不早于最大新鲜度窗口。

缺失、重复、过期、未来、未知状态或来源/仓库/SHA 错配都会返回 `blocked`。fixtures 不能替代真实观测；真实观测链尚未验收时，不得把候选结果提交为部署依据。

## Dry-run

```console
nix shell nixpkgs#nodejs_24 --command node utils/plan-observed-rollout.mjs \
  --plan ./rollout-plan.json \
  --inventory ./private-release-impact-inventory.json \
  --output ./rollout-candidate.json
```

退出码 `0` 只表示可提交给现有人工发布审阅，退出码 `2` 表示停止晋级。无论退出码为何，命令都不会访问生产系统或写入 Forgejo。

离线回归：

```console
nix shell nixpkgs#nodejs_24 --command node utils/test-observed-rollout.mjs
```

测试覆盖正常候选、共享模块展开、缺失/过期/未来/错误来源/错误 SHA/未知状态、未知路径、不完整批次、缺少停止条件、独立恢复缺失，以及存储变更强制单独审阅。

## 批次和停止条件

受影响主机多于一个时，第一批必须只有一个 canary。所有受影响主机必须恰好出现一次，不能漏项、重复或加入不受影响主机。每批执行前都重新采集真实 evidence，并用同一候选 SHA 重新 dry-run；前一批达到观察窗口后，才把输出交给下一次现有人工审阅。

操作包至少保留以下停止条件：

- `candidate-revision-drift`：checkout、发布或现场修订发生漂移；
- `control-channel-unavailable`：Forgejo、n8n、发布流水线或 Comin 控制通道不可用；
- `evidence-unhealthy-or-missing`：证据异常、缺失或越过新鲜度窗口；
- `host-or-service-regression`：任一主机或受影响服务回归。

任何停止条件触发后不进入下一批。认证、网络、存储或发布控制平面路径即使证据健康，也只返回 `blocked` 和 `separate_review_domains`，继续走各自现有专项审阅。

## 恢复

plan 必须绑定已经审阅、与候选不同的 `known_good_sha`。正常控制通道可用时，按既有生产流程选择该已知良好修订重新发布，禁止直接移动 `prod`。

inventory 还必须为每个受影响主机给出不依赖 Forgejo/n8n/Comin 的已验证通道和恢复步骤。NixOS 应通过带外或现存会话选择本机 `/nix/var/nix/profiles/system` 中已验证的 generation，并调用该 generation 的 `switch-to-configuration`；nix-darwin 应从本机 system generation 调用已验证的 activate 程序。具体 generation 必须在维护窗开始前记录，不能由 fixture 猜测。恢复后先验证主机和受影响服务，确认控制通道状态，再决定是否重新进入原审批流程。

若没有独立通道/步骤、现场 generation 未在窗口前验证、known-good 不可用或控制通道故障范围未知，保持停止并交由人工恢复，不尝试自动化回滚。
