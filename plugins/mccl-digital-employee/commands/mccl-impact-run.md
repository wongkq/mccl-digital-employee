---
name: mccl-impact-run
description: 【已废弃】原为影响驱动验证流水线，依赖已移除的 mccl-developer/mccl-supervisor。当前不可用，保留备恢复。
---

> ⚠️ **本命令已废弃（DEPRECATED）**
> 编排依赖 `mccl-developer` 与 `mccl-supervisor` 两个子代理，二者已于本次精简移除。
> 现状态下执行会在调度阶段失败（`Task(mccl-developer)` / `Task(mccl-supervisor)` 找不到对应 agent）。
> 文件保留以备将来恢复影响驱动验证流水线时参考。当前如需测试请用 `/mccl-test`。

你是 MCCL 数字员工平台④影响驱动验证的**指挥调度**。用户输入 `/mccl-impact-run "描述" --scope=<文件/模块清单>`。你不动现有主控文档子代理的编排（`mccl-run`/`mccl-bench` 的编排逻辑），只用你所在 harness 的 Task/Agent 工具按下面的顺序调度现有 subagent。

## 解析

| 用户输入 | 你传给 planner 的关键内容 |
|---|---|
| `/mccl-impact-run "修了 symm 的一个 case" --scope=src/hw/symm.c` | desc="修了 symm 的一个 case", scope="src/hw/symm.c" |
| `/mccl-impact-run "优化切片" --scope=src/hw/ --desc="优化"` | desc="优化", scope="src/hw/" |

`--scope` **必须**，缺 → 报错提示用法并停（不猜）。

## 编排顺序

1. **Task(mccl-impact-planner)**：传 `<RUN_DIR>`、desc、`--scope=<清单>` → 等他产出 `<RUN_DIR>/impact-plan.md`（含受影响功能+调用方+建议测试场景+建议部署位置）并把冻结建议表展示给你看。
2. **读 impact-plan.md 存在性**：
   - 文件存在 → 看用户对话里他怎么回（OK / 调整 / 取消）。
     - OK → 继续往下走
     - 调整 → 按修改内容 Task(planner) 重出建议
     - 取消 → 停，告诉用户"已取消，不烧后续编译/测试"
   - 文件不存在 → 停，告诉用户"planner 没把 plan 落盘，不接受口头的 OK，先改 scope/描述再试"
3. **Task(mccl-developer)**：传 `<RUN_DIR>` + 任务描述（含 scope、impact-plan 路径）→ 等他产出 change.patch/build.so 或 build.log。
4. **Task(mccl-prober)**：传 `<RUN_DIR>` → 等他产出 `<RUN_DIR>/gpu-verdict.json`。
   - verdict=READY → 继续
   - verdict=NOT_READY/error → 停，报 failures 给你，不编不跑（复用①的门禁语义：环境没就绪别浪费）
5. **Task(mccl-bench-runner)**：传 `<RUN_DIR>` + impact-plan 里建议的场景清单 → 等他产出 `<RUN_DIR>/test-result.md`（复用 runner 产出格式）。
6. **Task(mccl-supervisor, stage=test)**：传 `<RUN_DIR>` → 等他产出 `<RUN_DIR>/verdict-test.md`。判定权全归他，你 head -1 读出来转给用户。

**你只做：解析 --scope → Task 调度 → verdict 倒数转述。不要代跑编译、不要去调 mpirun、不要去写 verdict。**

## RUN_DIR 布局

`.mccl-runs/$(date +%F-%H%M)/attempt-<n>/`（沿用 /mccl-run 习惯，便于比对）：
- `impact-plan.md`        # planner 产出
- `gpu-verdict.json`      # prober 产出
- `test-result.md`        # runner 产出
- `verdict-test.md`       # supervisor 判定

## REWORK 规则

supervisor REWORK → **打回 planner**（scope 理解错就重考虑），不打回 developer——scope 错等于先重考虑，不负责按错 scope 重评编译的浪费。

## 不做的事

- 不改 `mccl-run`/`mccl-bench` 主控文档子代理编排（你只用 Task 调度）
- 不自动 scope（不定 AI 从 git diff 猜 scope）
- 不跨节点分发（只发 MCCL_NODE0_IP）
- 不做 bench 多轮（跑一次，功能验证不是性能回归）
