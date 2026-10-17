# Forgejo 线性历史约束

`infrastructure/infra` 的服务端 `pre-receive` hook 拒绝向分支引入新的多父提交。
它覆盖普通分支、AGit 提交与 PR head；Forgejo 合并 PR 时执行的内部 Git push
也经过同一个 hook。同一脚本也覆盖 `infrastructure/infra-private`；该仓库的历史
基线由 `infra-private` 自己固定和管理，详见私有仓的
`docs/operations/forgejo-linear-history-private.md`。标签、其他仓库不在本次策略
范围内，原有权限、审查、状态检查和生产发布审批仍由 Forgejo 与现有门禁执行。

## 历史基线与拒绝条件

启用时的 `infra/main` 为 `8f7f5bca82997220b268fcf7ed5032ba1017dd8f`。
该提交及其全部祖先作为固定历史基线，保存在 `hooks/infra-baseline`。
对每个待更新的分支，hook 检查所有可从新头部到达、但不属于基线的提交；
存在两个或更多父提交就拒绝整次 push。基线缺失或校验失败同样拒绝。

- 新建分支、普通推送、强推、一次推送多个 ref 使用相同规则。
- 分支删除放行给 Forgejo 权限检查处理。
- 已存在的标签、其他工作分支不能使新 merge commit 获得豁免。
- 基线之前的 merge commit 可以继承，无需重写主线历史。
- 尚未合入主线的旧工作分支若含基线之外的 merge，也需要先 rebase。

不要把基线自动更新为最新 `main`，也不要用 `--not --all` 排除其他 ref。
否则被提前推送到其他 ref 的 merge commit 可能被错误放行。

被拒绝后，在工作分支执行 `git fetch origin`、`git rebase origin/main`，
解决冲突并验证结果，再使用 `git push --force-with-lease` 更新自己的工作分支。
其他目标分支应使用对应的 rebase 目标；不要强推 `main` 或 `prod`。

## 部署与维护

源码在 `wanxiang/kubernetes/apps/development/forgejo/app/hooks/`。
Kustomize 生成 `forgejo-linear-history` ConfigMap，HelmRelease 只读挂载：

- 脚本 → `/data/git/gitea-repositories/infrastructure/infra.git/hooks/pre-receive.d/50-linear-history`
- 基线 → 同一裸仓库的 `hooks/linear-history-baseline`

同一脚本也挂载到 `infra-private.git` 的 `pre-receive.d/50-linear-history`。
私有仓基线来自 `infra-private` 生成的 `forgejo-linear-history-private`
ConfigMap（键 `infra-private-baseline`），本仓库只引用该名称，不保存私有基线。
该 ConfigMap 必须先在私有仓创建，否则 Pod 因缺少挂载源而无法启动。

hook 是 shell 代码，生成的 ConfigMap 带
`kustomize.toolkit.fluxcd.io/substitute: disabled`，避免 Flux postBuild 把
`$baseline` 等 shell 变量当成替换占位符（严格模式下会导致整个 Kustomization
失败）。不要把该注解加到需要 `${SECRET_DOMAIN}` 等替换的资源上。

保留 Forgejo 生成的 `hooks/pre-receive` dispatcher 和 `pre-receive.d/gitea`。
无需开启允许用户编辑 Git hooks 的 `DISABLE_GIT_HOOKS=false`。
ConfigMap 的 subPath 挂载需要重建 Pod 才能刷新，因此 Deployment 明确配置
Reloader 监听公开与私有两个 ConfigMap。新增适用仓库时，必须单独核对其历史
基线并增加挂载；私有基线与私有接线不要复制进本仓库。

首次上线可先由运维将相同脚本和基线原子写入现有 PVC 的对应路径，立即生效且
无需重启 Forgejo；后续由上述 GitOps 挂载接管。不要覆盖未知的同名自定义 hook。
回退时撤销挂载并移除该自定义 hook 文件；不要移除 Forgejo 自带的权限 hook。

2026-10-15 已将本页对应的脚本与基线安装到运行中实例的 PVC，未重启服务。
Forgejo 容器内的 19 项真实 receive-pack 测试通过，内置 dispatcher 与权限 hook
的校验和保持一致。原声明式挂载因 postBuild 对 shell 变量做严格替换而失败；
本次变更禁用该 ConfigMap 的替换并加入私有仓接线，合入后由 Flux 接管。

本地验证：`bash utils/test-forgejo-linear-history.sh`。测试使用真实本地裸仓库
和 `git push`，覆盖 quarantine 中的新对象、历史 merge、新建分支、隐藏的 merge、
强推、AGit、标签绕行、多 ref 原子拒绝、集中式 hooksPath 及基线故障。

## 升级准备（2026-10-15）

已核对 Forgejo `v15.0.10` 与 `v16.0.6` 的 `models/git/protected_branch.go`，
均没有独立的 `require_linear_history` 配置，升级不能替代此 hook。
14.x 已结束维护，建议另行准备升级到 **15.0.10 LTS**（支持至 2027-07-15）。
16.0.6 的支持截至 2026-10-29，对本实例优先采用 15 LTS。

当前是 Helm chart 16.2.1、应用 14.0.3-rootless、单副本、SQLite WAL，
仓库、数据库和附件在 `forgejo-data` PVC。版本迁移前需：

1. 阅读 15.0 的完整 breaking changes，核对 Helm chart 对目标镜像的兼容性。
   实例显式设置 `GITEA_APP_INI=/data/gitea/conf/app.ini`，不依赖 15.0 删除的
   `/etc/gitea/app.ini` 旧路径兼容逻辑；默认 cookie 更名会使现有用户重新登录。
2. 在维护窗口暂停写入、清空 Forgejo 队列，并取得包含 SQLite/WAL、仓库、
   附件和配置的同一时间点完整备份；验证恢复方法后再迁移。
3. 更新应用镜像并验证登录、SSH/HTTP push、PR 合并门禁、此 hook、Actions、
   packages/registry、n8n 与 Multica 集成。用隔离测试仓验证允许和拒绝路径。
4. 数据库已迁移后，回退必须恢复备份与旧镜像，不能只降级镜像。

15 LTS 升级尚未包含在本次 hook 配置中。以后升级 16+ 时，Forgejo 的内置
Git hooks 会集中管理；官方说明现有自定义 hooks 仍可保留，不能执行删除整个
`hooks/` 目录的可选清理步骤，应在升级验证中复测本策略。

来源：[发布状态](https://forgejo.org/releases/)、
[15.0 发布说明](https://forgejo.org/2026-04-release-v15-0/)、
[升级指南](https://forgejo.org/docs/latest/admin/upgrade/)。
