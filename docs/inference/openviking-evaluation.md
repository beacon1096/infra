[中文](openviking-evaluation.md) | [English](openviking-evaluation_en.md)

# OpenViking 部署评估

状态：2026-09-27 评估完成，暂不作为 Memoh 正式记忆后端。

## 结论

OpenViking 可以在 Wanxiang 部署单节点 PoC，用于验证文档导入、记忆抽取、检索、持久化和 MCP。当前部署的 Memoh v0.20.0 不能通过原生 Memory Provider 使用它，因此 PoC 不应接管正式 Bot 的记忆。

Memoh v0.20.0 的 OpenViking adapter 是占位实现：聊天前后 hook 不读写记忆，CRUD 返回 `openviking provider is disabled`。管理界面仍会显示 OpenViking 类型，上游文档也描述了配置字段，但这不代表该版本具备可用的运行时集成。

参考：

- [Memoh v0.20.0 OpenViking adapter](https://github.com/felinics/Memoh/blob/v0.20.0/internal/memory/adapters/openviking/openviking.go)
- [Memoh OpenViking 文档](https://github.com/felinics/memoh-docs/blob/main/docs/zh/integrations/providers/memory/openviking.md)

## PoC 范围

建议固定以下边界：

- 镜像固定为 `ghcr.io/volcengine/openviking:v0.4.21`，不使用 `latest`。
- 单副本 Deployment，更新策略为 `Recreate`。
- 一个 20 GiB Longhorn RWO PVC。
- ClusterIP 服务暴露 `1933`，初期不创建公网入口。
- 使用 API key 模式；root key 仅用于管理，日常访问使用用户 key。
- 首轮使用本地文件系统和本地向量库，不引入 PostgreSQL、Qdrant、Redis 或远程对象存储。
- 通过通用 MCP 连接 `/mcp` 做测试，不把它配置为 Memoh Memory Provider。

OpenViking 官方 chart 当前也限定单副本和 `Recreate`，本地 RocksDB/PVC 不支持多 Pod 并发。默认资源请求为 500m CPU、1 GiB 内存，限制为 2 CPU、4 GiB 内存，PVC 为 20 GiB。这些数值只适合 PoC 起点。

参考：

- [OpenViking v0.4.21 发布记录](https://github.com/volcengine/OpenViking/releases/tag/v0.4.21)
- [OpenViking Helm Deployment](https://github.com/volcengine/OpenViking/blob/v0.4.21/deploy/helm/openviking/templates/deployment.yaml)
- [OpenViking MCP 接入](https://docs.openviking.ai/en/guides/06-mcp-integration)

## 模型依赖

Embedding 是必需能力。模型输出维度必须与 OpenViking 配置及已有向量集合一致；更换模型或维度需要重新索引。VLM 用于语义摘要、记忆抽取和多模态理解，缺少可用 VLM 会降低 L0/L1 内容质量。

PoC 可先使用 OpenViking 默认本地 embedding，VLM 再接现有 OpenAI compatible 网关。若改用远程 embedding，API key 进入 SOPS Secret，配置中只引用 Secret。

Connect-It 的 OpenAI connector 是 MCP/SaaS connector，不是模型推理网关，不能作为 OpenViking 的 embedding 或 VLM endpoint。

参考：[OpenViking 配置说明](https://docs.openviking.ai/en/guides/01-configuration)。

## 验证清单

PoC 至少验证：

1. `/health` 与 `/ready` 在重启前后稳定。
2. API key 对管理接口和租户数据接口的权限边界符合预期。
3. 导入中英文 Markdown、代码和一个多模态样本。
4. session commit 后能生成记忆并通过语义检索召回。
5. MCP 客户端能执行查找与写入；断线重连不丢任务。
6. Pod 重建后 PVC 数据完整，备份和恢复步骤可复现。
7. 固定数据集记录召回质量、索引延迟、查询延迟、CPU、内存和磁盘增长。
8. 升级和回退一个固定版本，确认旧索引仍可读取。

## 转正门槛

满足以下条件后才能考虑成为 Memoh 正式记忆后端：

- Memoh 原生 OpenViking adapter 恢复完整的自动写入、自动召回与 CRUD，并有版本化测试。
- 明确 embedding 和 VLM 的长期承载位置、模型版本、维度及凭据轮换方式。
- 有 PVC 快照、恢复演练、容量告警和升级回退流程。
- 对生产 Bot 完成影子验证，证明记忆写入和召回不会静默丢失。
- 若要求多副本，先迁移到共享文件存储和远程向量后端，并完成并发验证。

在这些条件满足前，Memoh 内置 graph memory 加 pgvector 语义索引仍是正式路径，OpenViking 只作为独立实验服务。
