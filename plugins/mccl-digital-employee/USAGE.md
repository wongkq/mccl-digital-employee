# MCCL数字员工使用文档

安装、双根模型、节点数配置、run目录整体布局、重试速查表见`README.md`。本文档只讲"拿到装好的插件，怎么真的用它干活"。

## 1. 快速开始：从零到第一轮

```bash
# 1. 装插件（两种装法见 README「安装到真实仓库」，此处以插件装法为例）
/plugin marketplace add <本仓库的git地址>
/plugin install mccl-digital-employee@mccl-digital-employee

# 2. 在 MCCL 仓库根（mccl_dev_supernode）拷配置模板并填值
cd <你的MCCL仓库根>
cp ~/.claude/plugins/marketplaces/<marketplace>/plugins/mccl-digital-employee/mccl-env.sh.example ./mccl-env.sh
# 编辑 mccl-env.sh：填入 MCCL_NODES、MCCL_CONTAINER、MCCL_MACA_PATH 等18个变量的真实值

# 3. 配好本机到编译节点的免密
bash <插件根>/bin/mccl-setup-ssh

# 4. 在 MCCL 仓库根启动 claude
claude

# 5. 跑第一轮
/mccl-run <任务描述>
```

**必须在MCCL仓库根目录启动claude。** 四个子代理开工第一步都是`git rev-parse --show-toplevel`锚定`REPO_ROOT`，`mccl-env.sh`、MCCL源码、`.mccl-runs/`都挂在这个根下面（`agents/mccl-developer.md`第1节、`agents/mccl-tester.md`第1节、`agents/mccl-supervisor.md`第2节口径一致）。子代理继承的是主会话启动时的工作目录，不是它自己猜的路径——虽然在仓库子目录里启动`git rev-parse --show-toplevel`也能解析出仓库根，但主控在`commands/mccl-run.md`第2节里把`RUN_DIR`拼成`$REPO_ROOT/.mccl-runs/...`并作为绝对路径传给每个子代理；如果你在别的目录启动、又手动`cd`过仓库，容易在"我以为的仓库根"和"实际解析出的仓库根"之间产生认知错位，导致你后面手动拼路径（例如第2节场景化调用时）对不上。最省心的做法就是老老实实在仓库根启动。

## 2. 场景怎么调

### 2.1 完整流水线

```
/mccl-run 修复对称内存路径下 info.rank 越界访问 ipc_input_buffer 的问题
```

会做：调度`mccl-developer`→`mccl-supervisor(stage=dev)`→`mccl-tester`→`mccl-supervisor(stage=test)`→`mccl-reporter`→`mccl-supervisor(stage=report)`，全绿产出`final-report.md`；触发升级则产出`escalation.md`。不会做：自动commit、自动push、自动归档到`docs/reports/`（`commands/mccl-run.md`第9节，`README.md`"用法"一节同口径）。

### 2.2 只跑测试（库已编好、已分发好，只想复测）

调`mccl-tester`。**提示词里必须给绝对路径的run目录**——子代理继承的是主会话CWD，给相对路径它会写到别的地方去（`agents/mccl-tester.md`第1节"不要假设你的当前目录就是仓库根"）。示例提示词：

```
用 mccl-tester 子代理跑一次测试。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030/attempt-1
读该目录下 change.patch、dev-change.md、build.log（开发已产出）。
产出写到同一目录：test-preflight.md、test-asymmetric.log、test-symmetric.log、
test-result.md（单节点模式对应改为 test-singlenode.log）。
```

会做：按`$MCCL_NNODES`选场景，独立核对`libmccl.so`各节点md5（不采信开发自报值），跑对应`mpirun`，产出原始日志与`test-result.md`。不会做：改代码、改库、重新编译——`agents/mccl-tester.md`第5节硬约束第一条。这条路径不经过`mccl-supervisor`，判定是否合格要你自己看`test-result.md`或手动再调一次监督员。

### 2.3 只审计（不重新跑开发/测试）

调`mccl-supervisor`。**必须传`stage`**（`dev`/`test`/`report`三选一），它靠这个决定读哪份checklist（`agents/mccl-supervisor.md`第2节）。示例：

```
用 mccl-supervisor 子代理做一次审计，stage=test。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030
（本轮产物在其下 attempt-1/ 子目录）
```

会做：读对应checklist逐条核对落盘产物，写`verdict-<stage>.md`（report卡点是`verdict-report-<N>.md`），判决三选一（PASS/REWORK/ABORT），"理由"字段具体到文件行号。不会做：改任何文件——`agents/mccl-supervisor.md`第1节第2条，虽然它的`tools`里有Bash，但只准跑`git diff`/`md5sum`一类只读命令，这条约束由提示词自觉遵守，harness不强制拦它写文件或跑测试。

### 2.4 只写报告

调`mccl-reporter`，给run目录绝对路径。示例：

```
用 mccl-reporter 子代理写报告。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030/attempt-1
文件名：report-1.md（若是重写，改成 report-2.md，不得覆盖 report-1.md）
读该目录下 change.patch、dev-change.md、build.log、test-preflight.md、
test-asymmetric.log、test-symmetric.log、test-result.md（如有 test-anomaly.md 一并读）。
```

会做：核对产物、摘录、汇总成八段式`report-<N>.md`，每个数字标出处（文件名+行号）。不会做：执行任何命令去补数据——它的`tools`里没有Bash（`agents/mccl-reporter.md`第1节），遇到日志里找不到的数字，唯一能做的是写"未覆盖"。

## 3. 怎么读产物

- **`timeline.md`**——最先看这个。全程流水账，追加写、不分轮次，谁在什么时候被调用、判决是什么，一眼看完不用逐个进`attempt-N/`翻（`commands/mccl-run.md`第8节）。
- **`verdict-*.md`**——首行`判决: PASS|REWORK|ABORT`（`agents/mccl-supervisor.md`第3节，这是主控`head -1`解析的硬契约）；"理由"字段必须具体到文件行号；"标记项"是需要你人工决策但不阻断流水线的事，比如绕过性改动声明——PASS也可能带标记项，别只看判决字段就划过。
- **`final-report.md`**——只在全绿时出现，是主控从通过的那份`report-N.md`原样拷贝而来（`commands/mccl-run.md`第3节第113行）。
- **`escalation.md`**——只在ABORT或超限（`attempt`超3、`report_attempt`超2）时出现，看"升级原因"字段，格式见`commands/mccl-run.md`第6节。
- **`test-preflight.md`**——测试没跑起来时先看这个。多节点模式六条、单节点模式四条（`agents/mccl-tester.md`第4a、4b节），哪条没过、怎么核对的都写在里面。
- **`attempt-N/`**——按轮次分子目录，第2轮不覆盖第1轮。诊断门要求第3轮根因假设与前两轮不同，监督员靠跨轮读`attempt-1/dev-change.md`、`attempt-2/dev-change.md`比对；平铺到同一目录会让这项设计失效（`commands/mccl-run.md`第1节）。

## 4. 出问题怎么查

| 现象 | 原因 | 怎么办 |
|---|---|---|
| agent卡住不动、ssh没反应 | 密钥没配好，裸ssh弹密码提示，而agent背后没有人输密码 | 跑`bash <插件>/bin/mccl-setup-ssh`。所有ssh已带`$MCCL_SSH_OPTS`（`BatchMode=yes`）会立刻失败而不是挂起（`references/mccl-remote-ops.md`§0.5），若仍挂起说明有裸ssh漏网，跑`bash <插件>/tests/check.sh`第13条排查 |
| preflight md5不一致，测试不跑（多节点模式第2条） | **最常见**。编译节点`$MCCL_MACA_LIB_DIR/libmccl.so`没更新 | 这是`测试.md`原始工作流的洞：它记载的分发只有三条scp（发给非编译节点）加编译节点容器内到`/opt/maca/lib`的cp，编译节点的`$MCCL_MACA_LIB_DIR`从没写过，且全程只有`make -j50`没有`make install`。补`references/mccl-remote-ops.md`第3节"动作②"那条命令：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'cp $MCCL_REMOTE_SRC/build/libmccl.so $MCCL_MACA_LIB_DIR/'"` |
| agent说"找不到references/" | `TOOLKIT_ROOT`没解析对 | 插件装法应由`bin/mccl-toolkit-root`解析（优先`$CLAUDE_PLUGIN_ROOT`，兜底`$BASH_SOURCE`反推）；拷贝装法退回`$REPO_ROOT`。确认`references/`确实在插件根或仓库根下（`bin/mccl-toolkit-root`） |
| 主控直接停，提示`mccl-env.sh`不存在 | 没从`.example`拷贝 | `cp <插件>/mccl-env.sh.example ./mccl-env.sh`并填值（`commands/mccl-run.md`第2节第1点） |
| agent拒绝执行，说拓扑不受支持 | `MCCL_NNODES`不是1/4/8 | MCCL只硬编码了OAM32（4节点）/OAM64（8节点）。2/3/5节点时`CliqueManager::IsSupported()`的OAM32分支不匹配，对称内存路径不启用、静默fallback到Ring/Tree——**测出来的不是你以为在测的东西**，所以拒绝比跑更安全（`agents/mccl-developer.md`第1节第6点、`agents/mccl-tester.md`第2节） |
| 报告里写"缺失"，日志明明跑了 | 日志落在远端了 | `ssh`的重定向必须在引号**外面**：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "<命令>" > "$RUN_DIR/build.log" 2>&1`，写成`ssh ... "<命令> > build.log 2>&1"`日志就留在远端（`references/mccl-remote-ops.md`§0.6）。`mccl-reporter`没有Bash、取不了远程文件，日志不在本地对它等同不存在 |
| mpirun hang超5分钟 | 见`test-anomaly.md` | **禁止重启**（`references/mccl-safety.md`第3条）。agent会采`dmesg`+IB状态后停下等你（`agents/mccl-tester.md`第5节）。你也别手动重启——这条是`测试.md`原始规程里的硬禁令 |
| 监督员判REWORK："历史产物缺失" | 前几轮的`attempt-N/`不在 | 诊断门要跨轮读`attempt-1/dev-change.md`和`attempt-2/dev-change.md`比对根因假设（`references/supervisor-checklists/dev.md`第10条）。run目录必须按轮次分子目录，不能平铺 |
| SegFault | 已知故障模式 | 查`MCCL_P2P_LEVEL`是否与固件匹配（`agents/mccl-tester.md`第6节） |
| UDS Connection refused | 已知故障模式 | 确认`$MCCL_MACA_PATH`的`mcMemFabricHandle_t`是1112字节版本，不是80字节旧版stub（`agents/mccl-tester.md`第6节、`mccl-env.sh.example`第41-43行） |

## 5. 各角色边界速查

| 角色 | Bash | 能连测试机 | 能做什么 | 不能做什么 |
|---|---|---|---|---|
| `mccl-developer` | 有 | 能（ssh到编译节点、容器内编译） | 改源码、rsync同步、容器内编译（内循环上限5轮自修复）、按`$MCCL_NNODES`分发`libmccl.so` | 不commit、不push、不跑跨节点/多卡测试（`agents/mccl-developer.md`第5节） |
| `mccl-tester` | 有 | 能（ssh到全部节点、跑mpirun） | 按`$MCCL_NNODES`选场景跑测试、独立核对md5、产出原始日志 | 不改代码、不改库、不重新编译（`agents/mccl-tester.md`第5节） |
| `mccl-reporter` | **无** | **不能** | 读run目录已落盘产物，写报告，每个数字标出处，未覆盖场景标"未覆盖" | 不能执行任何命令去补数据——`tools`里没有Bash，这是防报告造假的**物理隔离**，不是疏漏（`agents/mccl-reporter.md`第1节、`tests/check.sh`不变式8） |
| `mccl-supervisor` | 有 | 有条件能（经跳板做只读`md5sum`/`ls`核实） | 在dev/test/report三道卡点独立审计，判PASS/REWORK/ABORT | 不修改任何文件、不跑测试、不重新编译——Bash只准只读用途（`git diff`/`md5sum`）。**这条"只读"靠提示词自觉，harness不强制**：它的`tools`里确实有Bash，技术上完全能用来写文件或跑命令，没有机制阻止（`agents/mccl-supervisor.md`第1节第2条） |
| 主控（`/mccl-run`） | 有限（仅`mkdir`/`date`/`head -1`/写自己的`task.md`等） | 不直接连 | 调度四个子代理、`head -1`解析verdict、维护`timeline.md`、判断打回目标 | 不代劳任何角色的活（不改代码、不编译、不跑mpirun、不写`dev-change.md`/`test-result.md`/`report-N.md`），也不自己下judgment——PASS/REWORK/ABORT的判断权只属于`mccl-supervisor`（`commands/mccl-run.md`第0节） |

## 两条诚实提醒

1. **第一次跑，人工盯完整一轮。** 这套agent的远程执行行为从未在真集群上端到端验证过。`plugins/mccl-digital-employee/tests/check.sh`的13条只验静态不变式（frontmatter是否合法、`mccl-reporter`是不是真没Bash、环境变量引用闭不闭合、已跟踪文件有没有私网IP字面量、有没有裸ssh漏网），验不了"开发agent会不会真的拒绝git push""监督员会不会真判ABORT""编译内循环会不会真的停在5轮"——这些都需要真实远程节点和真实32卡集群才能验证，本工具包不具备（`README.md`"已知限制"第1条）。首次在真实仓库使用，逐步核对每个子代理落盘的产物和每次verdict，不要直接放手跑完整流水线。

2. **单节点模式测不到跨节点对称内存。** 不是覆盖度低，是`info.rank % GROUP`这类bug在单节点下**有bug的代码和修好的代码行为完全一致**：单节点时`info.rank`只有0..7、`GROUP=8`，`rank % 8 == rank`。跨节点的8+3 slot、fabric handle、`37ba549`那一行代码全都不会执行（`README.md`"节点数配置"一节、`agents/mccl-tester.md`第2a节）。工具包会强制在`test-result.md`里声明这两点未覆盖（`references/supervisor-checklists/test.md`第3条，漏了判REWORK），但你要清楚这个声明的含义：单节点跑通不代表跨节点对称内存路径没问题。
