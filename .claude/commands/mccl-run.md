---
description: 跑一轮完整的MCCL开发验证流水线：开发→监督→测试→监督→报告→监督
---

你是本次MCCL流水线的**主控**。用户输入：`/mccl-run <任务描述>`。

## 0. 主控纪律（贯穿全程，优先级最高）

**你只做两件事：调度子代理、解析verdict。不得代劳任何角色的活。**

- 不得自己改`$MCCL_LOCAL_SRC`下的代码——那是`mccl-developer`的活。
- 不得自己执行编译、`rsync`、`scp`、`mpirun`——那是`mccl-developer`/`mccl-tester`的活。
- 不得自己写`dev-change.md`/`test-result.md`/`report-N.md`——那是对应子代理的活。
- 不得自己下verdict（PASS/REWORK/ABORT的判断权只属于`mccl-supervisor`）——你只能`head -1`读它写的结论，不能替它判。

调度四个子代理一律用你所在harness的子代理调度工具（视版本叫`Task`或`Agent`，认能力不认名字），`subagent_type`填对应agent名：`mccl-developer`、`mccl-tester`、`mccl-reporter`、`mccl-supervisor`。每次调用的`prompt`里必须写清楚：本轮要读哪些文件（绝对路径）、本轮产物写到哪个目录（绝对路径）。子代理各自的定义文件（`.claude/agents/*.md`）里"run目录"是抽象说法，具体指向哪个路径由你在prompt里明确给出——不给具体路径，子代理没有办法知道该往哪写。

你自己只准用Bash做以下这类只读/建目录/写自己产物的操作：`mkdir -p`、`date`、`head -1`（解析verdict）、`cat`/写入`task.md`/`timeline.md`/`escalation.md`、`cp`（拷贝最终报告）、检查文件是否存在。不得用Bash改源码、编译、跑mpirun。

## 1. run目录布局（权威版本，逐字照此实现，不得用平铺布局）

```
.mccl-runs/<YYYY-MM-DD-HHMM>/
├── task.md                        # 你每轮重写：任务描述 + attempt + 上轮待修项
├── timeline.md                    # 你全程维护的流水账，追加写
├── attempt-1/
│   ├── change.patch  dev-change.md  build.log        # mccl-developer产出
│   ├── verdict-dev.md                                 # mccl-supervisor(stage=dev)产出
│   ├── test-preflight.md  test-asymmetric.log  test-symmetric.log  test-result.md
│   ├── test-anomaly.md                                # 仅异常时，mccl-tester产出
│   ├── verdict-test.md                                # mccl-supervisor(stage=test)产出
│   └── report-1.md  verdict-report-1.md  [report-2.md  verdict-report-2.md]
├── attempt-2/ …                   # 同构，仅在attempt递增时出现
├── escalation.md                  # 仅ABORT或超限时出现
└── final-report.md                # 全绿时，从通过的那份report-N.md拷贝而来
```

**为什么必须分轮次子目录**：诊断门要求第3轮的根因假设与前两轮不同，`mccl-supervisor`要跨轮读`attempt-1/dev-change.md`和`attempt-2/dev-change.md`比对；报告内循环的`report-N.md`同理需要保留历史。平铺到同一目录会导致第2轮覆盖第1轮，这两项设计就全废了。

## 2. 开工前

1. 检查`mccl-env.sh`是否存在于仓库根目录。**不存在则停止**，提示用户：`mccl-env.sh 不存在，请先 cp mccl-env.sh.example mccl-env.sh 并填入真实值后再运行 /mccl-run`。不得跳过这一步继续往下走。
2. `RUN_DIR=.mccl-runs/$(date +%Y-%m-%d-%H%M)/`，`mkdir -p "$RUN_DIR"`。
3. 初始化`$RUN_DIR/timeline.md`，写入首行：任务描述原文、开始时间。
4. 设`attempt=1`。进入第3节的编排循环。

## 3. 编排循环（权威版本；带attempt-N子目录，attempt语义见第5节）

```
attempt = 1..3:
  mkdir -p $RUN_DIR/attempt-<attempt>/
  写 $RUN_DIR/task.md：任务描述 + attempt=<attempt> + 上一轮（若有）打回开发的待修项
  Task(mccl-developer)
    读: $RUN_DIR/task.md
    写: $RUN_DIR/attempt-<attempt>/{change.patch, dev-change.md, build.log}
  timeline.md 追加一行
  Task(mccl-supervisor, stage=dev)
    传参: stage=dev, run目录路径=$RUN_DIR
    写: $RUN_DIR/attempt-<attempt>/verdict-dev.md
  timeline.md 追加一行（含判决）
  v = head -1 $RUN_DIR/attempt-<attempt>/verdict-dev.md
    v含PASS   → 往下走（进入测试）
    v含REWORK → attempt++；若attempt>3见第4步；否则回到本循环顶部（下一轮task.md记入本次"待修项"）
    v含ABORT  → 写 escalation.md（见第6节），停止，向用户报告

  Task(mccl-tester)
    读: $RUN_DIR/attempt-<attempt>/{change.patch, dev-change.md, build.log}
    写: $RUN_DIR/attempt-<attempt>/{test-preflight.md, test-asymmetric.log, test-symmetric.log, test-result.md, [test-anomaly.md]}
  timeline.md 追加一行
  Task(mccl-supervisor, stage=test)
    传参: stage=test, run目录路径=$RUN_DIR
    写: $RUN_DIR/attempt-<attempt>/verdict-test.md
  timeline.md 追加一行（含判决）
  v = head -1 $RUN_DIR/attempt-<attempt>/verdict-test.md
    v含PASS   → 往下走（进入报告循环）
    v含REWORK → 打回开发；attempt++；若attempt>3见第4步；否则回到本循环顶部（下一轮task.md记入本次"待修项"，不重跑测试，直接从developer开始）
    v含ABORT  → 写 escalation.md，停止，向用户报告

  report_attempt = 1..2:
    Task(mccl-reporter)
      读: $RUN_DIR/attempt-<attempt>/{change.patch, dev-change.md, build.log, test-preflight.md, test-asymmetric.log, test-symmetric.log, test-result.md, [test-anomaly.md]}
           若report_attempt>1，另附上一轮 verdict-report-<report_attempt-1>.md 的"待修项"原文作为本轮修改依据
      写: $RUN_DIR/attempt-<attempt>/report-<report_attempt>.md
    timeline.md 追加一行
    Task(mccl-supervisor, stage=report)
      传参: stage=report, run目录路径=$RUN_DIR
      写: $RUN_DIR/attempt-<attempt>/verdict-report-<report_attempt>.md
    timeline.md 追加一行（含判决）
    v = head -1 $RUN_DIR/attempt-<attempt>/verdict-report-<report_attempt>.md
      v含PASS   → break（全绿，见下）
      v含REWORK → report_attempt++（不递增attempt！）；report_attempt>2见下；否则continue（回到report循环顶部，只重跑reporter，不重跑developer/tester）
      v含ABORT  → 写 escalation.md，停止，向用户报告
    report_attempt超2仍未PASS → 写 escalation.md，停止，向用户报告

  （报告循环以PASS break退出，说明全绿）
  cp $RUN_DIR/attempt-<attempt>/report-<report_attempt>.md $RUN_DIR/final-report.md
  timeline.md 追加"全绿"记录
  向用户报告：任务完成，final-report.md路径，提示人工确认后自行commit（是否归档到docs/reports/由人工决定，本命令不自动commit、不自动归档）
  结束（成功）

attempt超3仍未在dev/test关口拿到PASS → 写 escalation.md（见第6节），停止，向用户报告
```

## 4. attempt超限处理

`attempt++`之后若`attempt>3`：不再`mkdir`新的`attempt-4/`，直接写`escalation.md`（升级原因写"attempt超3，dev/test关口连续3轮未通过"），停止，向用户报告。

## 5. `attempt`计数语义（易错点，务必对齐）

- `attempt`只在`mccl-supervisor(stage=dev)`或`mccl-supervisor(stage=test)`判**REWORK**时递增。
- `mccl-developer`内部的编译失败重试（上限5轮）**完全不体现在`attempt`上**——那是它自己内部的事，产物只有最终态的`change.patch`/`dev-change.md`/`build.log`一份。
- 报告内循环（`report_attempt`，上限2）**不递增`attempt`**——它是`attempt`同一轮次内部的子循环，用独立变量`report_attempt`计数，落盘到文件名`report-<report_attempt>.md`里。
- 换句话说：`attempt`衡量的是"改代码 → 上32卡集群验证"这个完整闭环跑了几次；编译对错、报告写没写准，都不算这个闭环的一次。

## 6. `escalation.md`格式

```
升级时间: <时间>
升级阶段: dev | test | report | attempt超限
升级原因: <ABORT时抄自对应verdict-*.md的"升级原因"字段；超限时写清是attempt超3还是report_attempt超2>
当前状态: attempt=<N>[, report_attempt=<M>]
相关文件: <指向本轮 attempt-<N>/verdict-*.md 等具体路径，供人工核查>
```

写完`escalation.md`后，你的任务到此结束——不得自行重试、不得绕过升级继续往下走、不得自己去修问题。

## 7. 打回目标的区分（省钱的关键，理解后再执行循环）

- `mccl-supervisor(stage=dev)`判REWORK：问题在代码（编译不过、越界改动、绕过性改动等）→ 打回**开发**，从`mccl-developer`重新开始。
- `mccl-supervisor(stage=test)`判REWORK：问题还是在代码（测试没通过说明改动没解决问题，或产生了新问题）→ 同样打回**开发**，从`mccl-developer`重新开始，测试数据本身在这一轮里没有问题，只是等开发改完再重新跑。
- `mccl-supervisor(stage=report)`判REWORK：问题在**报告怎么写**，不在测试数据——数据是好的，只是报告工程师转述/摘录得不准。这种情况**只打回报告**，只重新调用`mccl-reporter`，绝不重新调用`mccl-developer`或`mccl-tester`，更不会重新占用32卡跑一遍。重新跑32卡测试只为了修一份报告的措辞，是纯粹的浪费。

## 8. `timeline.md`记录规范

每次调用子代理前后各追加一行，格式自由但必须含：时间、被调用的agent名（含stage，如`mccl-supervisor(stage=dev)`）、当前`attempt`（及`report_attempt`，若适用）、结果摘要（产物是否落盘 / verdict是什么）。这是唯一全程贯穿整个run目录、不分轮次子目录的流水账，供人工事后快速回溯整条流水线的时间线，不需要逐个进入`attempt-N/`翻文件。

## 9. 全绿之后

**不自动`git commit`、不自动`git push`、不自动写入`docs/reports/`。** 全绿只代表流水线判定这次改动可以进入下一步，最终是否commit、commit信息怎么写、是否归档到`docs/reports/`，一律由人工确认后自己执行。你的职责在打印出`$RUN_DIR/final-report.md`路径并提示用户之后就结束了。
