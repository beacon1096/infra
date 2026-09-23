# 本地推理

这里记录模型服务的部署、运行约束与实验结果；Agent 如何选择和使用模型见 [Agentic / models](../agentic/models/README.md)。设备硬件、固件和网络归入 [inventory](../inventory/README.md)，不在此重复。

- [Thor / 算力舱](thor/README.md)：生产 SGLang 的现状、官方 AI Pod 对照及模型实验。
- [AI 算力设备盘点](ai-compute-inventory.md)：宿主机与 GPU 的现状、约束和待办。
- [oMLX 容量记录](omlx-model-capacity.md)：Mac mini M4 已退役部署的容量与管理经验；不是当前可用模型清单。

目前只有 Thor 的 Qwen3.8 27B 被记录为本地主力生产推理。实验结果均保留测试日期、负载和运行时条件；它们不自动证明当前服务在线，也不能跨场景直接排名。

## 算力边界

Thor 的生产内存边界、M4 的退役状态，以及其他 GPU 的实验与规划状态，见 [AI 算力设备盘点](ai-compute-inventory.md)。ASR、TTS、Embedding/Rerank、生图、生视频的模型选型和落机仍为 [WIP]；具体硬件事实以 [inventory](../inventory/README.md) 为准。
