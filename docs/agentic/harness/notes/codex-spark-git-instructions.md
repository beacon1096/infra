# Codex Spark 拒绝执行 Git 的一次排查

日期：2026-09-13。环境：Codex CLI 0.154.0，`gpt-5.3-codex-spark`。

## 现象

通过 Paseo 使用 Spark，界面已选择 Full access。用户明确要求完成验证后提交推送，
模型却拒绝执行 Git，先声称仓库 `AGENTS.md` 禁止使用 Git；读取文件确认没有此规则后，
又改称来自会话全局约束。

## 定位结果

本机 `~/.codex/models_cache.json` 中，`slug` 为 `gpt-5.3-codex-spark` 的模型条目，
其 `model_messages.instructions_template` 包含以下内容（节选）：

```text
## Validation behavior
UNLESS you are explicitly requested to do so,
- NEVER do another pass just to check.
- NEVER review code you've written.
- NEVER list anything to verify that it is there or gone.
- NEVER read any files you have written.
- NEVER use git
- NEVER run tests or validate your work.
```

这份模板与原会话及新建 CLI 测试会话的 `session_meta.base_instructions.text`
逐字相同。当时缓存中的 8 个模型，只有 Spark 的模板包含 `NEVER use git`；
本机 `config.toml` 没有基础指令覆盖配置。

缓存带有 `fetched_at`、`etag` 和 `client_version`，本机 Codex 二进制中未找到
该禁令的明文。这支持模板来自远端模型目录的推断，但尚未严格确认最上游来源或作者。

## 对照测试

绕过 Paseo，直接新建只读 CLI 会话：

```sh
codex exec -m gpt-5.3-codex-spark \
  -c 'model_reasoning_effort="xhigh"' \
  --skip-git-repo-check --sandbox read-only --json \
  '请做一个只读诊断：直接执行 git --version 并报告结果。不要修改任何文件。如果你的生效指令禁止执行此命令，请说明限制来自哪一层指令。' </dev/null
```

模型成功执行命令，返回 `git version 2.54.0`，并声称当前约束没有禁止该命令；
但新会话日志仍包含上述模板。因此 Paseo 不是该模板出现的必要条件。

注意模板有“除非明确要求”的前提，不能把节选中的 `NEVER use git` 单独解释成
无条件禁令。新测试明确要求运行命令，其执行本身不证明违反模板；原会话也已明确
要求提交推送，却仍拒绝，且错误地归因于用户的 `AGENTS.md`。两次任务不同，
这不是严格控制变量的指令遵循评测。

## 经验

- Full access 是执行权限设置，不能据此推断模型收到的文字指令内容。
- 模型声称“规则禁止”时，应核对实际指令来源，不只检查仓库 `AGENTS.md`。
- 排查时同时查看模型缓存模板和会话实际保存的基础指令；缓存可能随后更新。
- 此发现仅针对当时加载的 Spark 模板，不能推广到所有 Codex 模型或模型规模。
  不经 Codex 调用的自建模型，没有证据表明会自动继承这份模板；需检查其自身调用端的提示词。

本文仅保留通用排查信息，不收录完整会话日志或私人环境信息。
