# Thor 推理引擎记录

这里收纳模型实验中发现、可能适用于其他模型的运行时问题。各项结论只在原记录的硬件、镜像、检查点与测量条件下得到验证；迁移到其他模型前仍需复测。

- [SGLang 客户端断连取消](../thor-sglang-abort-fix.md)：已派发请求的生命周期与中止修复；[英文原版](../thor-sglang-abort-fix_en.md)。
- [DFlash2、FA4、长上下文预填充](../model/qwen3.8-27b/lazycat.md#使用-lazycat-检查点的本地-sglang)：从 Lazycat 检查点的本地调优中提取的引擎行为；[原版复测](../model/qwen3.8-27b/original.md#dflash-块大小对比2026-09-13)另有块大小对比。
- [Flash Next 的 CUDA Graph、GDN 与量化](../model/qwen3.8-flash-next/original.md#运行时与算子兼容性)：SM110 适配中暴露的内核与加载问题；适用范围需按模型分别验证。
- [NInfer SM110 实验](../model/qwen3.8-27b/original.md#ninfer-sm110-后续试验2026-09-14)：集成内存预算、服务共存与原生内核探测。相关[源码补丁](patches/ninfer-sm110-complete.patch)、[内存预算补丁](patches/ninfer-linux-integrated-memory.patch)和[探测程序](probes/ninfer-sm110-native/native-probe.cu)在本目录归档；均属实验资产，不代表当前生产引擎。
