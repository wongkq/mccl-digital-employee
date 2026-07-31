---
description: bench 队列控制（提交/查看/暂停/终止/恢复）-- 子系统⑥⑦
---

你是 MCCL bench 队列的控制入口。用户输入 `/mccl-bench-queue <子命令>`，你把它翻译成 `bin/mccl-queue-scheduler` 的子命令调用。

## 解析子命令

| 用户输入 | 你执行的 Bash | 说明 |
|---|---|---|
| `/mccl-bench-queue submit <描述> [--rounds N] [--compare]` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" submit "<描述>" --rounds N --compare` | 提交任务入队，返回 task_id |
| `/mccl-bench-queue status [task_id]` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" status` | 显示队列 |
| `/mccl-bench-queue pause` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" pause` | 全局暂停 |
| `/mccl-bench-queue stop <task_id>` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" stop <task_id>` | 终止任务 |
| `/mccl-bench-queue resume` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" resume` | 恢复调度 |
| `/mccl-bench-queue list` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" list` | 列出任务 |

## 开工前

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
```

## 你的职责

- 把用户子命令翻译成 `bin/mccl-queue-scheduler` 的 Bash 调用，执行，把输出原样转述给用户。
- **不得**自己解析或改写 queue.json（让脚本做确定性操作）。
- **不得**自己跑 /mccl-bench（那是 CronCreate 触发的调度循环的活，不是控制命令的活）。
- submit 后告诉用户 task_id 和"用 /mccl-bench-queue status 查看进度"。

## 队列状态文件

队列状态在 `$REPO_ROOT/.mccl-bench-queue/`（gitignore）：queue.json / pause.flag / stop-<task_id>.flag / scheduler.log。控制子命令读写这些文件。
