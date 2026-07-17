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

**`MACA_PATH`出现两次且值不同，不一定是违规**：走全量重编时，`references/mccl-build-pitfalls.md`第3条的export序列会先把`MACA_PATH`临时指向`$MCCL_VENDOR_MACA_PATH`（只为派生`MACA_CLANG_PATH`/`CUDA_PATH`等工具链变量），**最后一行再改指`$MCCL_MACA_PATH`**才跑cmake。这是规定动作。判据是**cmake/make执行那一刻生效的值**：以`build.log`里最后一次`export MACA_PATH=`的值为准，它必须是`$MCCL_MACA_PATH`。只因为日志里出现过`$MCCL_VENDOR_MACA_PATH`就判REWORK，是误判。

## 7. `build.log`是否有新增warning → 有则标记

怎么查：`build.log`中grep`warning:`，统计条数与内容，和`dev-change.md`"编译结果"字段里"新增的编译warning"逐条核对。若`build.log`里有而`dev-change.md`未列出，除标记外，这一条也说明"变更清单/编译结果自述与产物不一致"，一并计入判断。

## 8. 编译是否通过；内循环额度是否已用尽 → 未通过且轮次≥5则**ABORT**

分两步查，两步用的证据来源不同，别混：

**第一步，编译是否通过 → 以`build.log`为准。** 看末尾有无编译成功的标志（无`error:`、有生成`libmccl.so`的记录）。`dev-change.md`自报"通过"而`build.log`末尾有`error:`，以`build.log`为准（第1节原则：只认证据不认声明），判REWORK。

**第二步，内循环用了几轮 → 以`dev-change.md`"编译结果"字段的逐轮记录为准。** 开发被要求一轮一条、写明每轮的报错摘要与对应改动（见`.claude/agents/mccl-developer.md`第7节），**数条目数**即得轮次。

- **不要试图从`build.log`里数失败次数。**`build.log`是**单次**make的完整输出（开发第8节的定义），只反映最终那一轮，里面没有前几轮的失败记录——想拿它佐证轮次是查不到的，那不是开发瞒报的证据。
- 逐轮记录缺失，或只写了一个总数而没有逐轮报错摘要 → 轮次无法核实，按证据不足处理，判REWORK（不得因为查不到就默认"没超"而放行）。
- 逐轮记录的最后一条标"通过"、`build.log`末尾却有`error:` → 自述与产物矛盾，以`build.log`为准，判REWORK。

**后果，按两步的结果组合判：**

| 编译是否通过（build.log） | 轮次（逐轮记录条目数） | 判决 |
|---|---|---|
| 通过 | 1~5，任意 | 本条不触发（轮次多少不单独构成问题） |
| 未通过 | **≥5** | **ABORT** |
| 未通过 | <5 | REWORK（打回开发继续修） |
| 未通过 | 无法核实 | REWORK（证据不足） |

为什么ABORT的门槛是"≥5"而不是">5"：开发第4.3节明令**5轮未通过就必须停止、不得有第6次**。正常执行下`>5`永远观察不到，拿它当触发条件这一条就是死条文；而真正会发生的状态——第5轮结束、仍未通过、轮次正好等于5——落在"≥5"里。这个状态就是内循环额度已用尽、5轮都没修好说明改动方向本身有问题，不该再给一个`attempt`去重跑5轮编译，直接升级人工。

轮次>5（即开发自己突破了5轮上限，做了第6次及以后）同样落在"≥5"里，一并ABORT——它还额外违反了开发第5节的硬约束。

## 9. 是否含绕过性改动 → **标记，不得自动PASS**

怎么查：读`dev-change.md`"绕过性改动声明"字段。同时独立扫`change.patch`里是否有跳过某段逻辑/禁用某个检查/注释掉失败代码的模式（即使该字段写"无"）。历史上`021417e`、`a703e97`两个skip式补丁都是这种模式且都已被revert（详见`references/mccl-safety.md`第8条）。只要`change.patch`或`dev-change.md`任一方显示存在绕过性改动，"标记项"字段必须写明具体是哪处、出自哪个文件哪行，不得因为已经声明就直接给PASS而不标记——声明是否属实、是否需要人工决策，是"标记项"存在的意义。若`dev-change.md`写"无"但`change.patch`里能看到绕过模式，属于第1条"声明与patch不一致"，按更严重的一方处理（不一致REWORK之上再标记）。

## 10. 第3轮专项：根因假设是否与前两轮不同 → 相同或属绕过性质则**ABORT**，不给第4轮

仅在本轮`轮次`＝3时执行。怎么查：读本轮`dev-change.md`的"## 根因假设"字段，与前两轮的`dev-change.md`"## 根因假设"字段（历史存放方式见`.claude/agents/mccl-supervisor.md`第2节第4点；找不到历史产物按证据不足处理，判REWORK而非放行，不得因查不到就默认PASS）逐句比对实质内容——不是比对措辞，是比对"认定问题出在哪"这件事本身。若第3轮假设与第1轮或第2轮实质相同（只是换了说法），或第3轮改动本身属于绕过性质（见第9条）而非真正定位根因，判ABORT，不再给第4轮机会。理由：连续两轮同一假设不成立，说明诊断方法本身有问题，不该再用同一思路修第三次。

## 11. `libmccl.so`是否已分发到4节点 → 否则REWORK

怎么查：`dev-change.md`"编译结果"字段必须列出**五个**具体md5值——构建产物本身（`$MCCL_NODE0_IP`容器内`$MCCL_REMOTE_SRC/build/libmccl.so`）＋四个节点（**含Node 0**）上mpirun实际会加载的那份`$MCCL_MACA_LIB_DIR/libmccl.so`（即`$MCCL_LD_LIBRARY_PATH`的库目录部分，**不是容器内`/opt/maca/lib`那份**，两者同名不同层，见`references/mccl-remote-ops.md`第2节）。五个值必须完全一致。

Node 0是最容易出问题的一个：它既是编译节点又要被分发，产物在`build/`而不在`$MCCL_MACA_LIB_DIR`，需要一次单独的容器内`cp`（`references/mccl-remote-ops.md`第3节动作②）才会到位。若五个值里对不上的恰好是Node 0那一份，八成是这一步被漏了。

笼统写"已分发"、"已同步"这类无法核实的表述，判REWORK。列了但五个值不全一致，说明分发没真正生效，判REWORK。

有Bash执行条件时，经`$MCCL_NODE0_IP`跳板抽查`md5sum`核实自报值属实（跳板/引号写法见`references/mccl-remote-ops.md`第1、5节）。不具备执行条件时，至少要求五个值齐全且一致。

注：测试agent会在开跑前**独立重算**这五个md5、不采信开发自报值，这是设计好的交叉验证。你这一关查的是"有没有如实列出"，测试那一关查的是"列的是不是真的"。
