# MCCL数字员工工具包

MCCL（MetaX Collective Communications Library）开发验证流水线的数字员工工具包：四个agent + 三道监督卡点 + 分层重试，用来在真实MCCL仓库（`mccl_dev_supernode`）里跑一轮"改代码 → 上32卡集群验证 → 出报告"的完整闭环，并让每一步的产出都经独立监督员审计。

**本仓库只存agent定义与静态自检，不产生运行产物。** 运行产物（`.mccl-runs/`）在拷贝到真实仓库、配好`mccl-env.sh`之后才会出现。

## 这是什么

四个角色：

| Agent | 职责 | 工具 |
|---|---|---|
| `mccl-developer` | 改源码、同步编译节点、容器内编译、分发`libmccl.so`到4节点。编译失败内循环自修复（上限5轮）。不commit、不push、不跑测试。 | 含Bash |
| `mccl-tester` | 跑场景A（非对称内存）+ 场景B（对称内存）两个32卡`mpirun`测试，产出原始日志。不改代码、不重新编译。 | 含Bash |
| `mccl-reporter` | 读run目录产物，写验证报告，每个数字必须能在原始日志里找到出处，未覆盖场景标"未覆盖"不得推断。 | **无Bash**（见下） |
| `mccl-supervisor` | 在dev/test/report三道卡点独立审计，判PASS/REWORK/ABORT。只认落盘产物，不采信自述。 | 含Bash（只读用途） |

三道监督卡点：`stage=dev`（开发之后）、`stage=test`（测试之后）、`stage=report`（报告之后），全部由`mccl-supervisor`承担，每次调用都是独立开工，互不共享上下文。

分层重试：编译内循环（`mccl-developer`内部，上限5轮，不体现在`attempt`上）/ `attempt`（改代码→上32卡完整闭环，上限3轮，只有监督(dev)或监督(test)判REWORK才递增）/ 报告内循环（`report_attempt`，上限2轮，只重跑`mccl-reporter`，不重跑开发/测试）。详见下方速查表。

编排入口：`.claude/commands/mccl-run.md`，一次调用跑完整条流水线：开发→监督→测试→监督→报告→监督。

### 关于`mccl-reporter`禁Bash

这是本工具包里最重要的一处设计，值得单独说明：报告工程师的`tools`字段里没有`Bash`，这是一道**物理隔离**，不是配置疏漏。如果报告工程师同时具备执行能力，遇到数据缺失时就有可能"跑一下补个数字"——这个临时补的实验不在开发/测试两个环节的审计链条里，监督员看不到，事后也没人能复现。禁Bash让这种事在物理上不可能发生：报告工程师手里没有能执行命令的工具，遇到数字对不上原始日志，唯一能做的诚实动作就是写"未覆盖"。`tests/check.sh`的不变式8专门校验这一点。

## 安装到真实仓库

在`mccl_dev_supernode`仓库根目录执行（`<本仓库>`替换为本仓库的实际路径）：

```bash
mkdir -p .claude/agents .claude/commands
cp <本仓库>/.claude/agents/*.md    .claude/agents/
cp <本仓库>/.claude/commands/*.md  .claude/commands/
cp -r <本仓库>/references          .    # 含 supervisor-checklists/ 子目录，-r 会带上
cp <本仓库>/mccl-env.sh.example    ./mccl-env.sh
# 编辑 mccl-env.sh，填入真实的节点IP、路径、容器名等18个变量的真实值

# 合并（不要覆盖）真实仓库已有的 .claude/settings.json：
#   把本仓库 .claude/settings.json 里 permissions.deny 的5条规则
#   （git push / reboot / shutdown / halt / init）追加进真实仓库现有的 deny 列表
#   注意：check.sh 只校验其中3条（git push / reboot / shutdown），halt / init
#   漏掉了也不会报错，合并时自己对一遍

# 追加到真实仓库的 .gitignore（若已有类似条目则跳过）：
#   .mccl-runs/
#   mccl-env.sh
```

装完之后建议跑一次（把`<本仓库>`换成实际拷贝来源）：

```bash
bash <本仓库>/tests/check.sh
```

这份`tests/check.sh`本身也可以整份拷进真实仓库长期留用，作为每次改动agent定义/references后的静态自检。

## 用法

```
/mccl-run <任务描述>
```

主控会检查`mccl-env.sh`是否存在（不存在则停止并提示），然后创建`.mccl-runs/<YYYY-MM-DD-HHMM>/`，按下方流程调度四个子代理，直到全绿产出`final-report.md`，或触发升级写出`escalation.md`。**全绿之后不自动commit、不自动push、不自动归档到`docs/reports/`**——是否commit、commit信息怎么写，一律由人工确认后自己执行。

### run目录布局

```
.mccl-runs/<YYYY-MM-DD-HHMM>/
├── task.md                        # 每轮重写：任务描述 + attempt + 上轮待修项
├── timeline.md                    # 全程流水账，追加写，不分轮次
├── attempt-1/
│   ├── change.patch  dev-change.md  build.log
│   ├── verdict-dev.md
│   ├── test-preflight.md  test-asymmetric.log  test-symmetric.log  test-result.md
│   ├── test-anomaly.md            # 仅异常时出现
│   ├── verdict-test.md
│   └── report-1.md  verdict-report-1.md  [report-2.md  verdict-report-2.md]
├── attempt-2/ …                   # 同构，仅attempt递增时出现
├── escalation.md                  # 仅ABORT或超限时出现
└── final-report.md                # 全绿时，从通过的那份report-N.md拷贝而来
```

按轮次分子目录，不用平铺布局：诊断门要求`attempt`第3轮的根因假设与前两轮不同，`mccl-supervisor`需要跨轮读`attempt-1/dev-change.md`和`attempt-2/dev-change.md`比对；报告内循环的`report-N.md`同理需要保留历史。平铺到同一目录会导致第2轮覆盖第1轮，这两项设计都会失效。

## 重试与卡点速查表

| 循环 | 计数变量 | 上限 | 谁递增 | 递增后落到哪 |
|---|---|---|---|---|
| 编译内循环 | 不单独计数 | 5轮 | `mccl-developer`内部，不体现在`attempt`上 | 只保留最终态的一份`change.patch`/`dev-change.md`/`build.log`；每轮的报错摘要逐轮记在`dev-change.md`的"编译结果"字段——`build.log`只有最终一次`make`的输出，佐证不了轮次，监督员数的是那份逐轮记录 |
| 改代码→上32卡完整闭环 | `attempt` | 3轮 | 只有`mccl-supervisor(stage=dev)`或`stage=test`判**REWORK**时 | 新的`attempt-N/`子目录 |
| 报告内循环 | `report_attempt` | 2轮 | `mccl-supervisor(stage=report)`判**REWORK**时（不递增`attempt`） | 同一`attempt-N/`目录下新的`report-M.md` |

诊断门：`attempt`到第3轮仍未通过dev/test关口，视为连续失败，主控直接写`escalation.md`停止，不再开`attempt-4/`。第3轮开发前，监督员在`stage=dev`审计时要求本轮给出的根因假设与前两轮不同（同一假设改第三遍还不对，说明诊断方向本身错了，不该再机械重试）——这条约束写在`references/supervisor-checklists/dev.md`里，由监督员在审计时核对，不是主控自动强制。

打回目标区分（省钱的关键）：
- `stage=dev`判REWORK → 问题在代码 → 打回开发。
- `stage=test`判REWORK → 问题还是在代码（没解决问题或引入新问题）→ 同样打回开发，重新走`attempt`。
- `stage=report`判REWORK → 问题在报告怎么写，测试数据本身是好的 → 只打回报告，只重跑`mccl-reporter`，绝不重新占用32卡跑一遍测试。

## 目录结构

```
.claude/
├── agents/            mccl-developer.md / mccl-tester.md / mccl-reporter.md / mccl-supervisor.md
├── commands/           mccl-run.md（编排入口）
└── settings.json       权限deny规则（git push / reboot / shutdown / halt / init）
references/
├── mccl-domain.md               领域知识（对称内存、FC kernel等）
├── mccl-build-pitfalls.md       编译陷阱（含macaify增量编译坑）
├── mccl-safety.md                硬禁令（8条，违反则ABORT或REWORK）
├── mccl-remote-ops.md            远程调用模式手册（ssh跳板、docker exec引号嵌套、4节点分发差异）
└── supervisor-checklists/
    ├── dev.md      test.md      report.md      三道卡点各自的监督checklist
mccl-env.sh.example    18个MCCL_*环境变量模板
tests/check.sh          10条静态不变式自检
```

## 已知限制（诚实列出，不淡化）

1. **本仓库连不上远程节点，agent的远程执行行为从未端到端验证过。** `tests/check.sh`只验静态不变式（frontmatter是否合法、`mccl-reporter`确实没有Bash、环境变量引用是否闭合、已跟踪文件无私网IP字面量、`测试.md`不在git历史中），**不验agent行为**——开发agent会不会真的拒绝`git push`、监督员会不会真的判ABORT、编译内循环会不会真的停在5轮，这些都没有被验证过，因为验证它们需要真实的远程节点和真实的32卡集群，本仓库不具备。**首次在真实仓库使用，建议人工盯完整一轮**，逐步核对每个子代理落盘的产物和每次verdict，而不是直接放手跑。

2. **`.claude/settings.json`的deny规则只能拦截本机命令，拦不住隧道内命令。** deny列表按命令前缀模式匹配，例如`Bash(reboot:*)`能拦住本机直接执行`reboot`。但`ssh host "reboot"`在harness眼里匹配的是`Bash(ssh:*)`这个前缀，不是`reboot`本身，deny规则识别不到隧道内实际执行的命令，拦不住。这类风险目前只能靠两层软约束补位：agent提示词里的硬禁令（`references/mccl-safety.md`）+ 监督员事后审计核对产物。这是分层防御，不是单点防护，任何一层单独看都不完备。

3. **`mccl-supervisor`拥有Bash，"只读"这条约束纯粹靠提示词自觉，harness不强制。** 监督员需要跑`git diff`/`md5sum`等命令做只读核对，所以它的`tools`字段里必须有Bash。但harness不会区分"只读用途的Bash调用"和"写入/执行用途的Bash调用"——监督员的`tools`里确实有Bash，技术上它完全能用来改文件、跑测试、重新编译，没有任何机制阻止它这么做。这条边界能不能守住，完全取决于监督员自己是否遵守提示词里"你不修改任何东西"的约束，而不是任何技术强制。

4. **`references/`里的领域知识来自`测试.md`的提炼，可能有偏差，且反映的是某一时间点的环境状态。** `测试.md`本身是私有材料（不入库，见下），记录的编译路径选型、拓扑常量、内核选型边界等信息对应的是提炼那一刻的真实环境。如果真实仓库所在的硬件拓扑、MACA版本、内核路径发生变化，`references/`里对应的内容需要人工同步更新，工具包本身不会自动感知环境漂移。

## `测试.md`不入库

`测试.md`是私有参考资料（真实环境的调试记录、内网IP、主机映射等），永远不进入本仓库的git历史，已在`.gitignore`中拦截。`references/`下的四份领域知识文档是从`测试.md`提炼出的技术知识（编译陷阱、硬禁令、远程调用模式、对称内存等领域概念），环境相关的具体值统一收敛到`mccl-env.sh`（不入库，只提交`mccl-env.sh.example`模板）。

**这条边界只有一部分是自动校验的，其余靠人工把关**——说清楚哪部分是哪部分，比笼统说"已校验"有用：

| | 谁来把关 |
|---|---|
| 内网IP字面量 | `tests/check.sh`不变式3自动校验（已跟踪文件grep私网IP段） |
| `测试.md`本身不入库 | 不变式1（不在git历史）、不变式2（被`.gitignore`拦截）自动校验 |
| `mccl-env.sh`不入库 | 不变式4自动校验 |
| 主机名/末位八位组映射（如`Host3=<末位八位组>`） | **无自动校验**，靠review。写进已跟踪文件，`check.sh`照样全绿 |
| 真实文件系统路径 | **无自动校验**，且`references/`里**确实含**真实路径 |

关于最后一行：`references/`里出现`/opt/maca`这类厂商标准安装路径是**有意保留**的说明性上下文——不写清楚"`/opt/maca`是什么、为什么不能拿它编译"，`mccl-build-pitfalls.md`第1条就讲不成。规则是`mccl-remote-ops.md:5`和`mccl-build-pitfalls.md:5`各自声明的那条：**agent实际要执行的路径一律走`$MCCL_*`变量，字面路径只能出现在解释性文字里**。这比"不含真实文件系统路径"要宽，以这两份文档自己的声明为准。
