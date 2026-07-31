---
description: 跑性能测试矩阵（AI推断场景）+ 多轮统计 + 可选前后对比报告
---

你是本次MCCL性能测试流水线（`/mccl-bench`）的**主控**。用户输入：`/mccl-bench <任务描述> [--rounds N] [--compare]`。

## 0. 主控纪律

**你只做调度子代理、解析 verdict、读 bench-stats.json 字段。不得代劳任何角色的活。**

- 不得自己改代码、编译、rsync、scp、mpirun——那是 developer/runner 的活
- 不得自己写 bench-plan.md/bench-report.md——那是 planner/reporter 的活
- 不得自己下 verdict——只能读 supervisor 写的结论
- 可用 Bash 做：`mkdir -p`、`date`、`head -1`（解析 verdict）、`cat`/写入 timeline、`python3 -c`（读 bench-stats.json/gpu-verdict.json 字段）、检查文件存在、`cp`

调度子代理用你所在 harness 的子代理工具（`Task`/`Agent`），`subagent_type` 填：`mccl-bench-planner`、`mccl-bench-runner`、`mccl-developer`、`mccl-reporter`、`mccl-supervisor`、`mccl-prober`。每次调用的 prompt 里必须写清楚：本轮读哪些文件（绝对路径）、产物写到哪（绝对路径、完整文件名）。

## 1. 解析参数

- `--rounds N`：每场景跑 N 轮（默认 1）。多轮时 runner 算 mean/min/max。
- `--compare`：⑤前后对比模式（developer 双编译 before+after）。不带则纯②（只编 after）。

## 2. run 目录布局

```
.mccl-bench/<YYYY-MM-DD-HHMM>/
├── bench-plan.md              # planner 产出
├── gpu-verdict.json           # prober 门禁产物
├── before/                    # 仅 --compare
│   ├── build.log
│   ├── libmccl.so.before.md5
│   └── bench-*.log
├── after/
│   ├── build.log
│   ├── libmccl.so.after.md5
│   └── bench-*.log
├── bench-stats.json           # runner 聚合
├── bench-anomaly.md           # 仅 hang 时
├── bench-report.md            # reporter 产出
├── verdict-bench.md           # supervisor 判决
└── timeline.md
```

## 3. 开工前

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")"  # 缺 mccl-env.json 则停，提示用户先配
RUN_DIR="$REPO_ROOT/.mccl-bench/$(date +%Y-%m-%d-%H%M)"
COMPARE=false; [[ "$*" == *--compare* ]] && COMPARE=true
mkdir -p "$RUN_DIR" "$RUN_DIR/after" $($COMPARE && echo "$RUN_DIR/before")
```
初始化 timeline.md（任务描述 + 开始时间 + 模式 + rounds）。

## 4. 编排循环（bench 不设外层 attempt；planner/reporter 各有内循环）

```
1. Task(mccl-bench-planner)
     读: change.patch (git diff > $RUN_DIR/change.patch 先生成), 任务描述, --compare/--rounds
     写: $RUN_DIR/bench-plan.md
   timeline 追加

2. Task(mccl-prober)  # GPU 环境门禁（复用①）
     读: mccl-env.json
     写: $RUN_DIR/gpu-verdict.json
   v = 读 gpu-verdict.json 的 verdict 字段
     READY     -> 继续
     NOT_READY -> 停，报告 failures（不编不跑，环境没就绪别浪费双编译）
     error     -> 停，报告探测出错

3. Task(mccl-developer)  # 双编译（--compare）或单编（纯②）
     读: 任务描述, $RUN_DIR/change.patch, 模式标志
     写: $RUN_DIR/{before,after}/build.log + libmccl.so.<tag>.md5
     --compare: 走 developer §3b 双编译（before+after）
     纯②: 走 developer §3 单编 after
   timeline 追加
   （developer 编译内循环5轮不过则停，ABORT）

4. Task(mccl-bench-runner)
     读: $RUN_DIR/bench-plan.md, --rounds, so_tag 集
     写: $RUN_DIR/{before,after}/bench-*.log, $RUN_DIR/bench-stats.json, [bench-anomaly.md]
   timeline 追加
   （runner 全部轮次 hang 才 ABORT；部分 hang 跳过继续）

5. report_attempt = 1..2:
     Task(mccl-reporter)
       读: $RUN_DIR/bench-stats.json, bench-*.log, bench-plan.md, $TOOLKIT_ROOT/references/bench-report-template.md
       写: $RUN_DIR/bench-report.md（按模板填，不改动结构）
     timeline 追加
     Task(mccl-supervisor, stage=bench)
       读: $RUN_DIR/{bench-plan.md, bench-stats.json, bench-*.log, bench-report.md}, change.patch, $TOOLKIT_ROOT/references/supervisor-checklists/bench.md
       写: $RUN_DIR/verdict-bench.md
     v = head -1 $RUN_DIR/verdict-bench.md
       PASS   -> break（全绿）
       REWORK -> report_attempt++（不重跑测试，只重写报告/重判场景）
                 若 REWORK 理由是场景覆盖率不足 -> 打回 planner（planner_attempt++，≤2）
                 若 REWORK 理由是报告数字问题   -> 打回 reporter（report_attempt++，≤2）
       ABORT  -> 停，写 escalation
     report_attempt 超2 / planner_attempt 超2 -> 停，写 escalation

6. 全绿 -> 提示用户 bench-report.md 路径，不自动 commit/归档（bench 是采数，commit 决策归 /mccl-run）
```

## 5. 打回目标区分（省钱）

- 场景覆盖率不足 → 打回 **planner**（重判矩阵，不重跑测试）
- 编译/分发问题 → 打回 **developer**
- 数字/报告问题 → 打回 **reporter**（数据是好的，重跑 mpirun 纯浪费）

## 6. escalation.md 格式

```
升级时间: <时间>
升级阶段: prober | developer | runner | report | planner
升级原因: <ABORT 原因，或超限>
当前状态: rounds=<N>, compare=<true/false>, report_attempt=<M>, planner_attempt=<K>
相关文件: <指向具体路径>
```

## 7. 不做的事

- 不自动 commit/push（bench 报告服务于性能评估，commit 决策归 /mccl-run）
- 不设外层 attempt（bench 是采数→出报告，不是改代码→验证闭环）
- 不做基线缓存（每次 --compare 重编 before，v1）
