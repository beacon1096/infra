# Thor SGLang 客户端断开连接后的中止修复

## 摘要

2026-09-15，Thor 固定版本的 SGLang 镜像在 Pi 转向新轮次或 HTTP 客户端断开连接后，仍可能让生成任务继续在调度器中运行。被遗弃的生成任务占用四个调度器槽位之一，直到自然结束前都会降低有效吞吐量。本文将这些只存在于调度器中的生成任务称为幽灵请求。

此修复回移了上游 SGLang 提交 [`f478b2bb2d582c09e7f1b4e49f0c2d039da8747a`](https://github.com/sgl-project/sglang/commit/f478b2bb2d582c09e7f1b4e49f0c2d039da8747a) 中的请求生命周期变更。该提交名为“Fix: abort handling for dispatched requests after client disconnect (#35255)”，其中的调度器条件已针对 Thor 固定的版本进行调整。

## 观察到的行为

两个 Pi 进程和两个活跃的 LiteLLM 连接产生了四个正在运行的调度器请求。额外的请求 ID 为：

- `120427ec3a94400e9de290668bb0754c`
- `20b85a89c6c6443daf24145f6072fbe3`

TokenizerManager 记录了对应的故障现象：

```text
Received output for rid='...' but the state was deleted in TokenizerManager.
```

两个幽灵请求最终完成；在没有客户端重新连接、也没有 multica 工作负载的情况下，调度器中的请求数先从四个降至三个，再降至两个。这排除了 multica 是额外并发来源的可能。GPU 时钟频率、利用率、温度和功耗模式均正常。

观察到的总生成吞吐量在四个调度器请求时约为 28–30 token/s，在两个请求时约为 21–25 token/s。短暂的单请求时段达到约 23.8 token/s。这些数字仅用于诊断并发带来的影响；DFlash 接受率调优仍处于冻结状态。

## 根因

固定版本的 TokenizerManager 在分词和分发之前就创建了 `rid_to_state`。其请求处理器的宽泛异常处理路径会调用 `_discard_pending_req_states()`，删除所有剩余状态，却不区分请求是否已到达调度器。

因此，已分发的流式请求断开连接时，可能依次发生：

1. 请求到达调度器并开始生成。
2. Pi 转向新轮次，或旧的 HTTP 流断开连接。
3. 处理器异常移除了该请求的 `rid_to_state` 条目。
4. 延迟的断连中止任务在两秒后运行。
5. `abort_request()` 找不到该 RID 的状态；在只有一个 tokenizer worker 的情况下，它直接返回，没有向调度器发送 `AbortReq`。
6. 调度器在没有客户端的情况下继续生成，直到自然完成。
7. 此后任何调度器输出都找不到对应的 TokenizerManager 状态，并发出上述警告。

直接删除调度器状态并不安全，因为中止必须经过调度器正常的结束流程，包括重叠调度、DFlash 和混合 Mamba 状态的清理。

分块预填充还存在一个相关的调度器竞态。如果请求作为当前活跃的分块请求而被延迟中止，且在处理该延迟中止前移到了其他队列，待处理的中止标记可能被丢弃，而正常的中止路径不会重试。

## 回移补丁

声明式补丁及清单为：

- `hosts/personal/fixed/thor/inference/tokenizer_manager.py.patch`
- `hosts/personal/fixed/thor/inference/scheduler.py.patch`
- `hosts/personal/fixed/thor/inference/manifest.json`

TokenizerManager 现在会：

- 记录每个请求是否已成功分发；
- 记录中止请求是否已发送；
- 仅删除分发前失败的请求状态；
- 为已分发请求向调度器发送幂等的中止请求，并保留其状态直至调度器完成清理；
- 如果中止请求本身分发失败，则重置幂等标记；
- 跟踪批量并行采样生成的 RID；
- 仅在传输层分发成功后，将单个请求和批量请求标记为已分发；
- 让延迟的断连任务只中止仍然存在状态的请求。

当一个延迟中止的分块请求已离开分块槽位、但仍占有请求池分配时，调度器现在会重试 `abort_request()`。上游此处使用 `req.kv.holds_kv`；Thor 固定版本使用可用的等价生命周期信号 `req.req_pool_idx is not None`。

启动时会从 `hosts/personal/fixed/thor/inference.nix` 中固定的镜像提取原始文件，校验其原始 SHA256 值，以零 fuzz 应用补丁，校验生成文件的 SHA256 值，并将修补后的文件以只读方式绑定挂载。更新镜像时，必须有意同步更新两个补丁和清单中的哈希值。

## 验证

2026-09-15 完成的验证：

- 使用 `patch --batch --fuzz=0` 重放两个补丁；
- 使用 `python3 -m py_compile` 编译两个修补后的 Python 模块；
- 构建 `.#nixosConfigurations.thor.config.system.build.toplevel`；
- 将生成的 NixOS 闭包部署到 Thor；
- 在运行中的容器内，按清单中的结果哈希校验两个已挂载文件；
- 确认 `thor-inference.service` 处于活跃状态，且 `/health` 返回成功；
- 启动一个设置了 `max_tokens=4096` 的流式请求，接收 6899 字节，然后在三秒后强制客户端超时；
- 在随后几次检查中未观察到残留的 decode 请求，后续生成健康探测报告运行中和排队中的请求数均为零；
- 在重启及取消请求后，未观察到 `state was deleted in TokenizerManager`、traceback 或调度器错误。

取消请求检查有意只覆盖一个请求，并非性能基准测试。今后升级镜像时应重复此检查；如果固定的 SGLang 版本改变了相关队列的生命周期，还应包括在分块预填充期间取消请求的检查。
