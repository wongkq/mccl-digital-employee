# report卡点checklist（卡点3：准确性）

stage=report时使用。产物来源：`report.md`，交叉核对`change.patch`、`dev-change.md`、`build.log`、`test-preflight.md`、`test-asymmetric.log`、`test-symmetric.log`、`test-result.md`、`test-anomaly.md`（如有）。审计原则见`.claude/agents/mccl-supervisor.md`第1节：只认证据，不认声明。

每条格式：检查项 → 怎么查 → 违反后果。

## 1. `report.md`每个数字能否在`test-*.log`中找到出处 → **逐个抽查，找不到出处的数字即REWORK**

怎么查：读`report.md`"证据索引"节列出的文件名与行号/行范围，从"测试覆盖""编译结果""与基线对比"等节里抽取关键数字（带宽、延迟、退出码、md5、warning条数等），逐个打开对应的`test-*.log`/`build.log`，核实指定行号处确实存在这个数字、且数值一致。抽查覆盖至少每节一处；只要有一处数字在指定出处找不到或对不上，判REWORK。

## 2. 未跑的场景是否标"未覆盖"而非从其他场景推断 → REWORK

怎么查：先按`references/supervisor-checklists/test.md`第2、3条的方式独立确认场景A/B是否实际执行（`test-asymmetric.log`/`test-symmetric.log`是否存在且非空，`test-result.md`是否标"未跑"）。若某场景未跑，核对`report.md`"测试覆盖"节是否原样写"未覆盖"及原因；若该节写出了具体数字（哪怕数值看起来合理，是从另一场景或经验推断出来的），判REWORK。

## 3. 结论是否与测试结果一致。测试FAIL但报告称PASS → **ABORT**

怎么查：读`test-result.md`两个场景各自的PASS/FAIL判定，与`report.md`"结论"节的表述逐句比对。任一场景判FAIL，而"结论"节写"可以commit"、或未提及该FAIL、或用"基本通过"之类模糊表述掩盖FAIL，直接ABORT。

## 4. `dev-change.md`中自评的风险是否在`## 遗留风险`中体现 → REWORK

怎么查：对比`dev-change.md`"自评风险"字段的要点与`report.md`"遗留风险"节，确认每个要点都被提及，没有被整段删减或替换成无关内容。

## 5. `dev-change.md`的绕过性改动声明是否原样体现、未被淡化 → REWORK

怎么查：读`dev-change.md`"绕过性改动声明"字段。若该字段声明了具体的绕过性改动，逐句核对`report.md`"遗留风险"节中对应描述——措辞强度是否被软化（例如把"跳过了某项检查"改写成"做了优化调整"这类淡化表述），具体位置（文件/函数）是否被省略。原文声明为"无"时不受本条约束。发现淡化或省略，判REWORK。

## 6. 变更清单是否来自`change.patch`而非`dev-change.md`自述 → REWORK

怎么查：核对`report.md`"变更清单"节列出的文件/函数改动，是否都能在`change.patch`的实际diff中找到对应内容。若`report.md`列出的内容只在`dev-change.md`"变更清单"字段出现、`change.patch`里找不到对应改动，说明报告工程师抄了开发的自述而未核实原始diff，判REWORK。

## 7. 报告循环是否超2轮 → **ABORT**（同一份数据写两次还不准，说明数据本身有歧义）

怎么查：**不要用`task.md`的`attempt`判断这一条。**`attempt`是外层计数器（改代码→上集群验证的完整轮次），报告内循环**不递增**它——报告重写三次，`attempt`纹丝不动。拿它当判据，这条检查永远不会触发。

正确判据是数文件：本轮报告写入的是`<run>/attempt-<attempt>/report-<N>.md`，`N`就是报告内循环的次数。你正在审的是`report-3.md`（即同一批开发/测试产物已第3次撰写报告），本条触发，直接ABORT——不再给第4次机会去修同一份数据的报告。

同时核对`<run>/attempt-<attempt>/`下已存在的`verdict-report-1.md`、`verdict-report-2.md`：前两次都判了REWORK却还没写对，说明问题不在报告工程师的文笔，在测试数据本身有歧义，该升级人工而不是让它再写一遍。
