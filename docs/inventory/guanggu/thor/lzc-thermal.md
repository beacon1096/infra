# Thor 上的懒猫 AI Pod 温控

[Thor 系统与固件](system.md)

2026-09-18 的只读检查追踪了 AI Pod 2.2.4 的风扇档位：从管理界面、后端和算力舱设备代理，直到一台 Jetson AGX Thor T5000 上的风扇守护进程。证据包括已安装的前端资源、Go 程序中的符号和诊断字符串、后端访问日志、实时设备信息接口、守护进程 Unix socket 接口及最终的 sysfs PWM 值。此文不保留认证材料或设备标识。

下文描述当时观察到的行为，并非稳定公开 API。设备代理和后端是带版本的私有实现细节，未来可能不兼容地变化。

## 控制链

设备记录含 `lzcThermalProfile` 时，设备信息组件才显示风扇档位选择器：

| 界面名称 | 接口值 |
| --- | --- |
| 安静模式（Quiet） | `<Max-Q>` |
| 性能模式（Performance） | `<Max-P>` |

切换档位会调用：

```text
GET /backend/device/lzcthermal/setProfile
    ?serialNumber=<device>&profile=<Max-Q|Max-P>
```

应用侧 Caddy 去掉 `/backend` 前缀，把请求发往 8070 端口的 AI Pod 后端，由 `DeviceManager.setLzcThermalProfile` 处理。捕获到的一次成功请求选择了 `<Max-P>`，耗时 19.5 ms。

后端再把请求转给经过认证的设备代理。代理发布 `_ai_jetson._tcp`，在 40793 端口提供带版本的设备 API；温控接口为 `/v1/lzcthermal/setProfile`。没有设备令牌时直接修改返回 HTTP 403。安装的代理在 `backend/client/thermal.go` 中包含 `SetThermalProfile`、`GetThermalProfile` 和 `formatThermalProfile` 处理逻辑。

代理通过 `/run/lzc-thermal/daemon.sock` 与 `lzc-thermald` 通信。`GET /config` 可用于只读诊断；当前控制器状态也保存在 `/run/lzc-thermal/config.json`。该文件是运行时状态，不是持久声明。

`lzc-thermald` 控制 `pwmfan` 硬件监测器并写入 PWM。安装懒猫守护进程时，代理会禁用 NVIDIA 的 `nvfancontrol.service`；诊断字符串显示，若懒猫守护进程配置或启动失败，会恢复 `nvfancontrol`。

## 观察到的风扇曲线

控制器处于自动模式，每 100 ms 采样 `gpu-thermal` 和 `cpu-thermal`，取较高温度。守护进程返回的档位如下：

| 档位 | 温度 | PWM |
| --- | ---: | ---: |
| `<Max-P>` | 30 °C | 80 |
| | 70 °C | 180 |
| | 80 °C | 225 |
| | 100 °C | 255 |
| `<Max-Q>` | 20 °C | 0 |
| | 49 °C | 0 |
| | 50 °C | 30 |
| | 60 °C | 80 |
| | 70 °C | 128 |
| | 75 °C | 180 |
| | 80 °C | 200 |
| | 100 °C | 255 |
| `<full>` | 0 °C | 255 |

守护进程在相邻点之间线性插值。接口返回的 `hystereis` 值分别为：性能模式 1,000，安静模式 5,000，全速模式 100。温度约 52 °C 时观察到 PWM 40，与安静模式 50 °C/30 至 60 °C/80 的插值相符。

## 后端保存的档位与实际生效状态

AI Pod 后端保存的是 `<Max-P>`，访问日志也显示此前成功选择过性能模式。但设备重启进入适配后的 NixOS 环境时，`lzc-thermald` 重新生成运行时文件并选择 `<Max-Q>`。Unix socket 配置和代理的只读 `/v1/info` 接口均报告安静模式。

适配后的 NixOS 代理未完整替代出厂控制面：其服务转发组件反复无法连接本地 Traefik 接口；管理应用保留了过时的出厂系统设备记录，并将它标为离线；后续模型宿主操作还遇到协议不匹配。因此后端保存的性能模式未在 NixOS 上恢复。

这决定了模型实验应如何标注环境：

- 2026-09-17 晚至 09-18（北京时间）的官方 AI Pod/出厂系统测量采用性能模式。
- 2026-09-18 初次自托管 NixOS 测量，包括 SGLang 调优和限时 71 分钟稳定性测试，采用安静模式。

后续一次 NixOS 复测明确标记为性能模式，使用机群自有曲线，而非 `lzc-thermald`。829 个一秒采样覆盖短输出解码、真实 8 请求解码及冷启动 64K/128K 预填充：GPU 有效频率保持在 1,385–1,386 MHz，GPU 峰值温度 57.2 °C，PWM 范围 102–147。相对安静模式，64K 和 128K 的首字延迟变化分别仅为 +0.1% 和 +0.2%；更强散热带来温度余量，未测得长预填充速度提升。

该 NixOS 运行在有意停止前完成 34 轮正确测试，温度达到 70.2 °C，GPU 有效频率仍保持 1,385–1,386 MHz，未观察到热降频。

## NixOS 的控制边界

NixOS 配置不再尝试运行懒猫私有设备代理、Traefik 桥接或 `lzc-thermald`；出厂系统仍是测量完整官方 AI Pod 软件栈的参照。

NixOS 下风扇控制归机群声明式配置管理。主机专属控制器复现观察到的 `<Max-P>` 曲线，每秒读取 CPU 与 GPU 温区的较高值，并写入 `pwmfan/pwm1`。两路传感器都不可读时选择 PWM 255；一路暂时不可读时，继续使用另一路。该服务与 `lzc-ai-agent.service`、`lzc-thermald.service`、`nvfancontrol.service` 互斥，确保同一时间只有一个进程控制 PWM。这也避免依赖私有设备令牌或 AI Pod 模型宿主协议的兼容性。
