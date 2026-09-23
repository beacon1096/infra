# Agent 体系设计

某些个人设备并不方便保持持续开机；agent工作空间跨多个设备时 容易遗忘和丢失工作进度。
[WIP] 在最后完成本地分支的清空后：
- 所有自动化和agent主导变更走multica工单
- 所有长期roadmap走multica工单维护进度

Multica Agent 按任务情况转交、提交审查、合入后完成，或在暂时没有低影响面的实现办法时标记为 blocked；不额外定义统一的完成流程。

## Agent 分类
目前感觉分为如下类别
- 代码Agent
  - 执行各类代码维护（GitOps配置 或者 维护的其他git仓库等）
  - Copilot Agent： 辅助人类编码的一般Agent
    - 直接使用人类身份，视同人类操作
  - Autopilot Agent： 在接收到issue/pr等各种情况下 自动进行系列操作 直到阶段性结束、
- 通用Agent [TODO]
  - 各种一般操作，但很可能只按会话进行、不涉及具体issue等
  - 对外： IM Agent
    - 可以挂在群聊里面
    - 为了避免受攻击 环境受控、工具受限，预先定义支持的操作 （例如查询multica工单）
    - 可能只是传话筒，但是由于靠近IM侧 可以提供一定代码运行环境 便于快速Fact Check等
  - 对内： Generic Agent
    - 可能具有固定身份，且处理一些日常生活减负任务（例如财务）

## Agent 工具

工具清单、接入方式及核对结果见 [tools/](tools/README.md)。

Pi 的职责、exec 交互和记忆问题见 [harness/](harness/README.md)。

Multica、Coder 与 Paseo 的任务派发和运行位置见 [dispatcher/](dispatcher/readme.md)。

模型接入、本地推理现状与算力规划见 [models/](models/README.md)。

Forgejo CI/CD、n8n 与 Multica 的现有工作流见 [infra-ops/](workflow/infra-ops/README.md)。

## 层级
目前我们对于Agent执行层 按照 Agent自动Autopilot 和 人类辅助Copilot 分成两组，其中复用部分能力底座。

### 基础运行环境
定义Agent的基本工作环境。通用基座，目标是skill/mcp/本地二进制与shell环境通用。
- Agent运行时： codex和pi为主
- `Copilot`调度层： paseo daemon
- `Autopilot`调度层： multica daemon
- `IM Agent`调度层： [WIP]AstrBot
- `Generic Agent`调度层： [WIP]暂未实现
- 基础执行环境定义： NixOS环境 及其对应OCI镜像

### 调度
指定以上工作环境的具体运行位置。
- `Copilot` 运行于任意本地设备 以及 用户自建的Coder工作区内
  - 期望是： 以后纯粹个人工作学习生活用，不要用于当前infra的变更。没有集中的位置维护进度，容易白干
- `Autopilot` 运行于独立的Coder工作区
- `IM Agent` 目前暂时挂靠在microserver gen10plus
- `Generic Agent` 计划运行于万象集群。具体实现方法未定
