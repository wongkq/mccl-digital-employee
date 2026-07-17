# MCCL数字员工设计

日期：2026-07-17
状态：已确认，待实现

## 1. 背景与目标

MCCL（MetaX Collective Communications Library）派生自NVIDIA NCCL/AMD RCCL，运行在MetaX MXMACA GPU上。当前开发流程是人工串起来的：本地改代码 → rsync到远程节点 → 容器内编译 → 分发`libmccl.so` → 4节点32卡跑测试 → 通过则commit，失败则回本地重来。

目标是把这条流程拆成职责明确的Claude Code子代理，由一个编排命令调度，并引入独立监督员对每个阶段卡点审计。

### 交付物边界

本仓库（`nccl_digital_employee`）**只存agent定义**，是一个可移植的工具包。设计完成后，`.claude/agents/`、`.claude/commands/`、`references/`拷贝或符号链接到真实的MCCL代码仓库（`mccl_dev_supernode`）中使用。运行产物（run目录、报告）产生在真实仓库里，不在本仓库。

本仓库当前所在机器无法直连远程节点，因此本仓库内无法端到端验证agent的远程执行能力。这是已知限制。

## 2. 核心约束

**Claude Code的子代理之间不共享对话上下文。**

这不是缺陷，正是所需的隔离：监督员审计编译日志时，不会被开发工程师"我觉得这样改没问题"的说法污染。代价是**所有角色间的信息传递必须落盘**。整套设计围绕这一条展开。

由此推出一条贯穿全局的原则：**监督员审的是产物，不是声明**。开发说他改了什么不算数，`change.patch`说了算；报告说测试通过不算数，`test-*.log`说了算。

## 3. 角色定义

四个角色：开发（含编译）、测试、报告、监督。

### 3.1 mccl-developer（开发工程师，含编译）

**职责**：改源码 → rsync到Node 0 → 容器内编译 → 分发`libmccl.so`到4节点。

**工具**：Read、Edit、Write、Grep、Glob、Bash（ssh/rsync/scp）

**输入**：`task.md`（任务描述 + 当前轮次 + 上轮监督意见）

**输出**：
- `change.patch` — 工作区diff快照，监督员的审计基准
- `dev-change.md` — 开发自述，见下方结构
- `build.log` — 完整原始编译日志

**编译内循环**：编译失败自己修，上限5轮。编译不通过不得交付。5轮仍不通过则交出失败状态，主控判ABORT升级人工——编译5轮不过说明改动方向本身有问题，不是笔误。

**硬约束**：
- 只改本地仓库源码和远程`/opt/workspace/zb`目录下的内容
- 不`git commit`、不`git push`
- 不在Node 1/2/3（57/53/58）上编译或改源码，这三台只接受scp的`libmccl.so`
- 编译前必须`export MACA_PATH=/opt/workspace/zb/maca`。`/opt/maca`的`mcMemFabricHandle_t`是80字节旧版stub，正确版本1112字节含scatter buffer，用错会导致跨节点对称内存句柄异常
- 改`.cc`/`.h`后必须`rm -rf build/macaify`再`make`。macaify拷贝依赖CMake的`copy_if_different`，不检测源文件时间戳
- 交付前清理调试代码。调试期间允许`printf`/`cout`/`MCCL_DEBUG`宏，但交付的diff里不得残留

**`dev-change.md`结构**：
- **根因假设** — 认为问题出在哪。第2轮起必须与前轮对比；第3轮必须提出与前两轮不同的假设
- **变更清单** — 改了哪些文件、哪些函数
- **改动理由** — 为什么这么改能解决根因
- **影响面** — 影响对称路径 / 非对称路径 / 两者
- **绕过性改动声明** — 本次是否包含"跳过/禁用/注释掉"性质的改动。有则必须显式声明并说明理由
- **自评风险**

### 3.2 mccl-tester（测试工程师）

**职责**：核对执行前checklist → 跑场景A → 跑场景B → 汇总结果。

**工具**：Bash、Read、Write、Grep

**输入**：`libmccl.so`已由开发分发到4节点

**输出**：
- `test-preflight.md` — 执行前checklist逐条核对记录
- `test-asymmetric.log` — 场景A原始输出
- `test-symmetric.log` — 场景B原始输出
- `test-result.md` — 结果汇总
- `test-anomaly.md` — 仅异常时产出

**测试场景**：两个场景都必须跑，不得按改动范围裁剪。

| | 场景A（非对称内存） | 场景B（对称内存） |
|---|---|---|
| 二进制 | `$PERF_BIN_ASYM` | `$PERF_BIN_SYM` |
| 末尾参数 | 无 | `-R 2` |
| 验证目标 | 传统FC clique的IPC路径（回归保护） | `mcclCommWindowRegister` → `MCCL_WIN_COLL_SYMMETRIC` → `registerSymetricBuffers`对称内存路径 |

mpirun参数两个场景一致：`-np 32`、`-host`四节点各`:8`、`-mca pml ^ucx -mca osc ^ucx -mca btl ^openib`、`-mca btl_tcp_if_include $TCP_IF_INCLUDE`、`-x MCCL_PCIE_BUFFER_MODE=1 -x MCCL_ENABLE_FC=1 -x MCCL_P2P_LEVEL=PXB`、`-x LD_LIBRARY_PATH`。

场景A的作用是回归保护。对称内存的改动会碰到`registerSymetricBuffers`、`updateFcKernelCommonArgs`等两条路径共用的host代码，省掉场景A等于放弃回归保护。

**执行前checklist**（逐条核对并记入`test-preflight.md`）：
- [ ] IP仅限四个已知节点
- [ ] `libmccl.so`四节点均已更新（独立核对，不采信开发的声明）
- [ ] `-np 32`，`-host`包含且仅包含四个IP的`:8`
- [ ] `MCCL_P2P_LEVEL`和`MCCL_PCIE_BUFFER_MODE`已配置
- [ ] `btl_tcp_if_include`正确
- [ ] 场景A、场景B命令均已就绪

`libmccl.so`的分发由开发执行、由测试独立核对，这道交叉验证是故意的：`MACA_PATH`用错版本会导致`mcMemFabricHandle_t`是80字节stub、跨节点句柄直接异常，值得两个角色分别做和查。

**硬约束**：
- 不改代码、不改库、不重新编译。发现问题只能上报
- mpirun hang超过5分钟：**禁止重启**。采集`dmesg`和IB状态写入`test-anomaly.md`后上报
- 不对远程环境做任何破坏性操作

### 3.3 mccl-reporter（报告工程师）

**职责**：读run目录全部产物，写单次变更的验证报告。

**工具**：Read、Grep、Write。**禁用Bash**。

禁Bash是防报告造假的物理隔离。报告工程师没有跑测试的能力，报告里每个数字只能从`test-*.log`里摘，摘不到就必须写"未覆盖"。

**输出**：`report.md`

**结构**：
- 变更摘要（改了什么、为什么）
- 变更清单（来自`change.patch`，不是`dev-change.md`的自述）
- 编译结果（是否通过、新增warning、产物md5）
- 测试覆盖（场景A、场景B各自的命令、结果、关键数据）
- 与基线对比
- 遗留风险
- 结论（可否commit）
- 证据索引（每个结论指向哪个日志文件的哪几行）

**硬约束**：
- 每个数字必须能在原始日志中找到出处
- 未跑的场景标注"未覆盖"，不得从其他场景推断
- 结论必须与测试结果一致

### 3.4 mccl-supervisor（监督员）

**职责**：三道卡点，独立审计，判决PASS/REWORK/ABORT。

**工具**：Read、Grep、Bash（仅只读命令，如`git diff`、`md5sum`）

用一个agent配三份阶段checklist，checklist存于`.claude/agents/checklists/{dev,test,report}.md`，主控传入stage参数。不拆成四个agent：监督的方法论是同一套（只认证据、不认声明、判决三选一），差的只是检查项；拆开会让各自提示词里的审计原则逐渐漂移。

**输出**：`verdict-<stage>.md`

```
判决: PASS | REWORK | ABORT
阶段: dev | test | report
轮次: N
理由: <基于哪份产物的哪段内容>
待修项: <REWORK时必填，具体到文件和行>
升级原因: <ABORT时必填>
标记项: <绕过性改动等需人工决策但不阻断的事项>
```

**卡点1（dev）——规范性 + 编译完整性**：
- `change.patch`与`dev-change.md`声明是否一致（以patch为准）
- diff中是否残留调试代码
- 是否改了`/opt/workspace/zb`之外的文件 → ABORT
- 是否试图`git push` → ABORT
- 是否在57/53/58上编译 → ABORT
- `build.log`中`MACA_PATH`是否为`/opt/workspace/zb/maca`
- `build.log`是否有新增warning
- 是否含绕过性改动 → 标记，不得自动PASS
- 第3轮：根因假设是否与前两轮不同 → 否则ABORT
- `libmccl.so`是否已分发到4节点

**卡点2（test）——覆盖度**：
- 执行前checklist是否逐条核对并记录
- 场景A是否跑了 → 否则REWORK
- 场景B是否跑了 → 否则REWORK
- 测试命令是否与`mccl-env.sh`定义一致
- 日志是否是原始输出而非摘要
- 有无hang/SegFault未上报
- 是否发生重启等禁止操作 → ABORT

**卡点3（report）——准确性**：
- `report.md`每个数字能否在`test-*.log`中找到出处
- 未跑的场景是否标"未覆盖"而非推断
- 结论是否与测试结果一致（测试FAIL但报告称PASS → ABORT）
- `dev-change.md`中自评的风险是否在报告中体现

## 4. 编排流程

主控命令：`/mccl-run <任务描述>`

```
attempt = 1..3:
  开发（改代码 → rsync → 编译[内循环≤5] → 分发）
    └→ 监督(dev): 规范性 + 编译完整性
         REWORK → 带意见回开发，attempt++
         ABORT  → 停，写escalation.md
  测试（preflight → 场景A → 场景B）
    └→ 监督(test): 覆盖度
         REWORK → 打回开发，attempt++
         ABORT  → 停
  报告
    └→ 监督(report): 准确性
         REWORK → 打回报告（≤2轮），测试数据不重跑
         ABORT  → 停
  全绿 → 拷report.md到docs/reports/，提示人工确认后commit

attempt超3 → ABORT，写escalation.md交人工
```

**打回目标的区分**：编译失败、测试失败打回**开发**（问题在代码）；报告不准打回**报告**（问题在描述，测试数据是好的，重跑32卡是浪费）。这个区分省下大量无谓的远程执行。

**重试与现有工作流的咬合**：现行流程规定测试FAIL时不删除远程源码，正是为重试环准备的。第2轮开发改完后只需`rm -rf build/macaify && make -j50`增量编译，不必全量重来。因此回退不需要动git、不需要动远程环境。

主控全程维护`timeline.md`：谁在什么时候被调用、判决是什么。

## 5. 重试策略与诊断门

分层重试，因为失败成本差两个数量级：

| 循环 | 上限 | 理由 |
|---|---|---|
| 编译（开发内部） | 5轮 | 廉价失败：几分钟、不占集群、通常是笔误或类型不匹配 |
| 测试（开发↔测试） | 3轮 | 昂贵失败：占4节点32卡，几乎必然是真正的逻辑问题 |
| 报告 | 2轮 | 同一份数据写两次还不准，说明数据本身有歧义 |

**测试为什么是3轮而不是更多**：多给轮数不会提高成功率，反而会降低修复质量。第1轮诊断方向对，第2轮通常就修好；第3轮还不行说明根因假设是错的，继续重试只是在错误方向上打转，此时模型会开始绕路——改无关代码、加workaround、注释掉断言。

这有历史证据：`021417e`（skip cross-node LSA）和`a703e97`（skip UDS cross-node）两个已revert的临时补丁都是"跳过"而非"修复"，最后被`37ba549`的正式方案（Fabric handle + 全局bootstrapAllGather）取代。把轮数调大只会让这类补丁更容易混进来。

**诊断门**是比轮数更重要的约束：第3轮的`dev-change.md`必须提出与前两轮不同的根因假设，监督员读前两轮的verdict来判断。如果第3轮只是"再试试"或加skip绕过，直接ABORT，不给第4轮。

**绕过性改动的处理**：监督员对任何"跳过/禁用/注释掉"性质的改动单独标记。它不一定是错的——`37ba549`之前那两个补丁在当时也有存在意义——但必须显式提出让人工决策，不能悄悄混在PASS里。

**ABORT条件汇总**：
- 越界行为：改`/opt/workspace/zb`之外的文件、重启远程、`git push`、在57/53/58编译
- 编译内循环5轮不过
- 测试外循环第3轮的根因假设与前轮相同或属绕过性质
- 测试外循环超3轮
- 报告循环超2轮
- 报告结论与测试结果矛盾

## 6. 产物目录

角色间的唯一通信信道。产生在真实仓库中，非本仓库。

```
.mccl-runs/<YYYY-MM-DD-HHMM>/
├── task.md              # 原始任务 + 轮次 + 上轮意见
├── dev-change.md        # 开发自述
├── change.patch         # diff快照（监督员的审计基准）
├── build.log            # 原始编译日志
├── test-preflight.md    # 执行前checklist核对记录
├── test-asymmetric.log  # 场景A原始输出
├── test-symmetric.log   # 场景B原始输出
├── test-result.md
├── test-anomaly.md      # 仅异常时
├── report.md            # 最终交付物
├── verdict-dev.md
├── verdict-test.md
├── verdict-report.md
├── escalation.md        # 仅ABORT时
└── timeline.md          # 主控流水账
```

## 7. 环境参数化

所有环境细节抽到`mccl-env.sh`，agent一律读该文件，不硬编码。拷到真实仓库时只改这一个文件。

包含：四节点IP与Host编号映射、容器名、`MACA_PATH`、远程源码路径、本地源码路径、mpirun路径、场景A/B测试二进制路径、`btl_tcp_if_include`网段。

## 8. 领域知识注入

agent缺少MCCL领域知识就无法工作。例如不知道`extLsaRankList[r]`存的是world rank而非slot索引，第1轮就会写错。知识提炼进`references/`：

- **`mccl-domain.md`** — 对称内存8+3窗口slot语义、`extLsaRankList`存world rank、`info.rank % GROUP`的由来、FC AllReduce内核选型边界（oneshot 1B~16KB / unk 16KB+~16MB）、`fc8xn_3d_mesh_allreduce_unk`未启用及其阻塞bug
- **`mccl-build-pitfalls.md`** — macaify增量编译陷阱、mxcc符号链接问题、`MACA_PATH`两个版本的1112 vs 80字节差异
- **`mccl-safety.md`** — 硬禁令清单

## 9. git约定

**本仓库**：
- `.gitignore`包含`测试.md`——它是私有参考资料，永不入库
- `mccl-env.sh`不入库（含内网IP与主机映射），提供`mccl-env.sh.example`占位模板入库
- 入库内容：`.claude/agents/`、`.claude/commands/`、`references/`、`docs/`、`mccl-env.sh.example`

`references/`从`测试.md`提炼而来但入库，因为它是agent能否工作的前提。敏感信息与技术知识分离：具体IP、主机映射、路径只存在于`mccl-env.sh`（不入库），技术知识（对称内存语义等）进`references/`（入库）。

**真实仓库**（拷贝过去后需追加）：`.mccl-runs/`和`mccl-env.sh`加入`.gitignore`。

## 10. 不做的事

- 不做Workflow脚本编排（已选定subagents形式）
- 不做git层面的自动回退。失败即打回开发重做，远程源码保留供增量编译
- 不做远程`libmccl.so`版本回滚
- 不做性能基线数据库。基线对比由报告工程师读历史报告完成
- 不做正式对外交付报告模板。报告是单次变更的验证记录，服务于commit决策
