# Strata + Swift 1.5 推理实验（MicroServer Gen10 Plus）

设备背景与驱动状态见 [设备记录](./readme.md)；本次触发的供电故障见 [GPU 持续负载与供电](./power-and-load.md)。

实验目的：验证 [Strata](https://github.com/Niko1221/Strata)（Qwen3.8-Flash-Next 125B MoE 的本地推理框架）在本机的实际可用性。

## 环境

- 宿主机：`microserver-gen10plus`；GPU RTX A2000 12 GiB（Ampere sm_86）。
- 运行方式：Ubuntu 24.04 容器 + 手动 GPU 直通（`/dev/nvidia*`），非 NixOS 原生。
- 引擎：上游只发布 Windows 预编译；Linux 需自行用 CUDA 13.0 编译（sm_86）。
- 模型：Swift 1.5 `IQ2_XS`，32K 上下文，纯文本（未开图像）。

## CPU 指令集

CC150（Coffee Lake，8C/16T，3.50 GHz）实测 `/proc/cpuinfo` flags：

- 支持：`sse`、`sse2`、`sse3`(pni)、`ssse3`、`sse4_1`、`sse4_2`、`avx`、`avx2`、`fma`、`f16c`、`bmi1`、`bmi2`、`aes`、`adx`、`movbe`、`rdrand`、`rdseed`、`xsave`、`xsaveopt`
- 不支持：`avx512*`（f/bw/vl/dq/vnni/vbmi 全无）、`avx_vnni`、AMX

Strata 的 i-quant CPU expert 内核有 AVX-512（VNNI/VBMI）快路径，本机只能退回 AVX2，是吞吐差距的主要来源之一。

## 结果

- 资源占用：约 35 GiB RAM、10.7 GiB VRAM；native pack 约 1.4 GiB，expert cache 3999/24576 slots（约 16% experts 常驻显存）。
- 吞吐：约 **7–10 tokens/s**（引擎自报一次 181 tokens / 18.6 s = 9.7 tok/s）。

## 瓶颈分析

- **CPU 主导**：仅约 16% experts 驻留 12 GiB 显存，其余由 CPU（CC150，8C/16T，仅 AVX2）计算。参考基准为 6 核 Ryzen 7600（AVX-512）+ RTX 5070；AVX2 回流加上较弱的 GPU 是主要差距来源。
- **磁盘次要**：28.8 GB 的 n-gram / PLE 表按 token 随机读取，受 SATA SSD 延迟影响；模型加载约 0.93 GiB/s。生成稳态下磁盘开销仅量级个位数百分比，不是主因。
- 结论：稳态吞吐瓶颈为 **CPU(AVX2) + 12 GiB 显存 ≫ SATA RAID5 磁盘**。

## 稳定性

实验后期在一次 Web UI 请求期间触发主板供电故障（`Runtime Fault, System Board, P12V Main/AUX Regulators`），整机断电。完整时间线与遥测缺口见 [GPU 持续负载与供电](./power-and-load.md)。

## 善后

实验后已删除容器、移除 8080 的 tailscale serve 转发，主机恢复原状；模型数据（约 72 GB，`/home/beacon/strata`）暂留，待供电问题处理后决定去留。
