# dev卡点checklist（卡点1：规范性 + 编译完整性）

stage=dev时使用。产物来源：`change.patch`、`dev-change.md`、`build.log`，必要时`task.md`与前几轮的`verdict-dev.md`历史。审计原则见`.claude/agents/mccl-supervisor.md`第1节：只认证据，不认声明。

每条格式：检查项 → 怎么查 → 违反后果。

## 1. `change.patch`与`dev-change.md`声明是否一致（以patch为准）→ 不一致REWORK

怎么查：逐一核对`dev-change.md`"变更清单"字段列出的文件/函数，是否都能在`change.patch`的diff hunk里找到对应改动；反过来，`change.patch`里出现的改动是否都在"变更清单"里被提及。任一方向缺失（patch有而change.md未提，或change.md提到但patch里没有），即判不一致。

## 2. diff中是否残留调试代码（`printf`/`cout`/临时`MCCL_DEBUG`）→ REWORK

怎么查：在`change.patch`里只看新增行（以单个`+`开头，排除`+++`文件头行），grep是否出现`printf(`、`std::cout`、`cout <<`，或本次新增的`MCCL_DEBUG`宏用法。区分：若某处`MCCL_DEBUG`用法在改动前就已存在（diff中对应行不是`+`），不算违反；只有本次新增的才算。

## 3. 是否改了`$MCCL_REMOTE_WORKDIR`之外的文件 → **ABORT**

怎么查：本地仓库改动（`change.patch`覆盖的文件）不受此项限制。重点核实远程侧：读`build.log`和`dev-change.md`里出现的同步/分发目标路径（如`rsync`、`scp`、`cp`的目的地），确认均以`$MCCL_REMOTE_WORKDIR`开头。若`build.log`只含编译输出、没有留下同步命令的路径记录，视为证据不足，不得因此默认PASS——在"理由"里写明"证据不足，无法核实同步目标路径"，按此项REWORK处理（ABORT需要实际证据支撑，不能凭空升级；但证据缺失同样不能放行）。

## 4. 是否试图`git push`或`git commit` → **ABORT**

怎么查：`build.log`、`dev-change.md`全文grep`git push`、`git commit`关键字；有条件时，用Bash在本地仓库跑`git log --oneline -5`，核对没有出现开发子代理本轮新增的commit（对照任务开始前的HEAD，若不确定基线，至少确认当前HEAD与`change.patch`描述的"未提交改动"状态吻合，即改动仍是working tree里的diff而非已提交的commit）。

## 5. 是否在NODE1/2/3上编译或改源码 → **ABORT**

怎么查：`build.log`中grep`$MCCL_NODE1_IP`/`$MCCL_NODE2_IP`/`$MCCL_NODE3_IP`（或`mccl-env.sh`里对应的IP值），确认这三个IP只出现在分发（scp/cp目标）上下文里，不出现在`make`、`docker exec ... bash -c`编译命令的上下文里。

## 6. `build.log`中`MACA_PATH`是否为`$MCCL_MACA_PATH` → 否则REWORK

怎么查：`build.log`里grep`MACA_PATH`（如`export MACA_PATH=...`或环境回显），比对其值与`$MCCL_MACA_PATH`逐字相等。

## 7. `build.log`是否有新增warning → 有则标记

怎么查：`build.log`中grep`warning:`，统计条数与内容，和`dev-change.md`"编译结果"字段里"新增的编译warning"逐条核对。若`build.log`里有而`dev-change.md`未列出，除标记外，这一条也说明"变更清单/编译结果自述与产物不一致"，一并计入判断。

## 8. 编译是否通过；内循环是否超5轮 → 超限**ABORT**

怎么查：`build.log`末尾是否有编译成功的标志（无`error:`、生成`libmccl.so`的记录）；`dev-change.md`"编译结果"字段"内循环实际用了几轮"是否≤5。若`dev-change.md`自报轮次与`build.log`里能观察到的失败重试次数对不上，以`build.log`能佐证的次数为准；超过5轮（含自报超5轮或`build.log`证据显示超5轮）直接ABORT。

## 9. 是否含绕过性改动 → **标记，不得自动PASS**

怎么查：读`dev-change.md`"绕过性改动声明"字段。同时独立扫`change.patch`里是否有跳过某段逻辑/禁用某个检查/注释掉失败代码的模式（即使该字段写"无"）。历史上`021417e`、`a703e97`两个skip式补丁都是这种模式且都已被revert（详见`references/mccl-safety.md`第8条）。只要`change.patch`或`dev-change.md`任一方显示存在绕过性改动，"标记项"字段必须写明具体是哪处、出自哪个文件哪行，不得因为已经声明就直接给PASS而不标记——声明是否属实、是否需要人工决策，是"标记项"存在的意义。若`dev-change.md`写"无"但`change.patch`里能看到绕过模式，属于第1条"声明与patch不一致"，按更严重的一方处理（不一致REWORK之上再标记）。

## 10. 第3轮专项：根因假设是否与前两轮不同 → 相同或属绕过性质则**ABORT**，不给第4轮

仅在本轮`轮次`＝3时执行。怎么查：读本轮`dev-change.md`的"## 根因假设"字段，与前两轮的`dev-change.md`"## 根因假设"字段（历史存放方式见`.claude/agents/mccl-supervisor.md`第2节第4点；找不到历史产物按证据不足处理，判REWORK而非放行，不得因查不到就默认PASS）逐句比对实质内容——不是比对措辞，是比对"认定问题出在哪"这件事本身。若第3轮假设与第1轮或第2轮实质相同（只是换了说法），或第3轮改动本身属于绕过性质（见第9条）而非真正定位根因，判ABORT，不再给第4轮机会。理由：连续两轮同一假设不成立，说明诊断方法本身有问题，不该再用同一思路修第三次。

## 11. `libmccl.so`是否已分发到4节点 → 否则REWORK

怎么查：`dev-change.md`"编译结果"字段是否列出四节点各自的`libmccl.so`具体md5值（不是笼统写"已分发"、"已同步"这类无法核实的表述）。有Bash执行条件时，可经`$MCCL_NODE0_IP`跳板对四节点的实际库文件路径抽查`md5sum`，核实与`dev-change.md`自报的md5一致（跳板/引号写法见`references/mccl-remote-ops.md`第1、5节）；不具备执行条件时，至少要求`dev-change.md`列出四个具体md5值，否则判REWORK。
