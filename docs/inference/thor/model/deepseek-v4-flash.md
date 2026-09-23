# DeepSeek-v4 Flash：可行性评估

[Thor 概览](../../README.md)

状态：仅审阅了源码；尚未在 Thor 上部署或进行基准测试。审阅的部署版本：
`fdcd538fbf95fb15b2d6850db9613d22b2c889b8`.

## 容量与内核限制

DeepSeek 单台 Spark 部署方案还有两项限制。它使用经 REAP-K216 专家剪枝、
并采用 EXL3/Trellis 量化的模型，而不只是量化完整的原始模型。其默认启动配置
需要约 114.3 GiB 可用内存，在这台设备上几乎不给桌面环境留下空间。
该构建还明确针对 SM120/SM121 系列内核，包括 `CUTE_DSL_ARCH=sm_121a`；
仅修改 Torch 架构标志，不能证明其稀疏注意力和量化专家内核支持 Thor 的 SM110。
因此，下载模型并实验之前，先要完成移植工作。

## 外部结果对比

Lazycat 厂商的技术负责人在模型适配博客中报告，使用两台机器运行 DeepSeek
约为 70 tokens/s。这不能与单台 Thor 的结果直接比较。
本地部署实验首先选择了 [Flash Next](qwen3.8-flash-next/original.md)。

## 参考资料

- [审阅版本的 DeepSeek-v4 Flash 单台 Spark 部署方案](https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-One-DGX-Spark/tree/fdcd538fbf95fb15b2d6850db9613d22b2c889b8)
- [DeepSeek Spark 检查点和磁盘需求](https://huggingface.co/0xSero/deepseek-v4-flash-0731-spark)
- [DeepSeek Spark 运行时 Dockerfile 与架构目标](https://github.com/0xSero/deepseek-v4-flash-0731-spark-sparkinfer/blob/main/Dockerfile)
- [Lazycat 技术负责人的模型适配报告](https://manateelazycat.github.io/2026/08/29/model-adaptation-record/) — 外部结果，并非本地测量值。
