# Qwen3.8-27B：适配与采用方案

截至 2026-09 的仓库记录，Thor 的生产方案是 NixOS 上的 SGLang，使用 Lazycat 检查点及 DFlash2 block16；INT8 draft head、BF16 target head，原生 262144 token 上下文。最多 4 个活动生成共享 270336 token 驻留池，并非四路都能同时占满 256K。完整启动参数、路由和恢复方式以 [推理运维记录](../../thor-inference.md)及私有仓 `hosts/personal/fixed/thor/inference.nix` 为准；这里不将旧实验配置写成当前部署。

| 变体 | 适配状态与用途 | 记录 |
| --- | --- | --- |
| Lazycat 检查点 | 当前生产方案；官方应用测量是对照，自建 SGLang 的复测也记在同一篇中 | [lazycat.md](lazycat.md) |
| 原版 NVFP4 | 已完成本地复测、长上下文与 NInfer 等实验；不是当前生产检查点 | [original.md](original.md) |
| Huihui 去拒答版 | 已做功能冒烟和吞吐对比；未成为生产方案 | [huihui.md](huihui.md) |

当前没有把厂商公布的 768K/900K YaRN 范围视作本地验证结果；原生 256K 与延期验证清单见[原版容量记录](original.md#上下文容量评估及延期的-yarn-测试2026-09-14)。通用引擎问题、补丁和探测工具见 [引擎记录](../../engine/README.md)。
