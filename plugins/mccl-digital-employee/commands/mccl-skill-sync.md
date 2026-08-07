---
name: mccl-skill-sync
description: skill 经验同步调度入口（手动批准或定时 auto）——把本仓库未提交的经验改动（坑/场景/模板/文档/脚本）commit+push 到 gitlab/github
---

你是 MCCL 数字员工仓库的 **经验同步调度入口**（子系统3）。用户输入 `/mccl-skill-sync [auto]`。你不动 git，只把任务包装后传给 sync agent（`mccl-skill-sync`）。

## 解析

| 用户输入 | 你的动作 |
|---|---|
| `/mccl-skill-sync` | 包装 prompt 后传给 `mccl-skill-sync`（手动模式：展示改动清单 → 用户批准 → 执行） |
| `/mccl-skill-sync auto` | 包装 prompt 后传给 `mccl-skill-sync`（自动模式：只收已跟踪修改 → commit+push → 无人值守） |

## 开工前

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
```

## 包装 prompt（传给 subagent_type=`mccl-skill-sync`）

- 根锚定：REPO_ROOT / TOOLKIT_ROOT 绝对路径
- 把用户输入的 `auto` 参数原样转达，并注明模式区别：
  - **手动**：先给用户看「要改哪些文件 + 你估是什么经验」清单，等用户批准后再执行
  - **auto**：不打扰用户，自动完成（但仍要报告结果）
- 告诉 agent：sync agent 的活动边界——检查 check.sh → commit → push；不写新坑、不改其他 agent 的文档。

## 报告规则

- `SYNC:none` → 告诉用户「本仓库没有待同步的经验改动」
- `SYNC:blocked（check.sh 不绿）` → 告诉用户「check.sh 不绿，自己修好了再说」
- `SYNC:push-failed` → 告诉用户"commit 留在本地（见 log），sync概述 冲不动了，你自己 pull --rebase 再跑一次或手动 push"
- `SYNC:done` → 把 commit hash 和成功推到哪几个 remote 转给用户

sync agent 的完整定义 详见 `agents/mccl-skill-sync.md`。