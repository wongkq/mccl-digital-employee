# 测试矩阵与前后对比（子系统②⑤）设计

日期：2026-07-30
状态：已确认，待实现
所属：MCCL数字员工平台 7 子系统之二（② 测试自动化 + ⑤ 前后对比）。本 spec 合并②⑤，因为⑤（前后对比）本质是②（多组统计）的一个特例——前后两份 .so 就是两组数据。子系统①（GPU环境探测）已完成并合并 main。

## 1. 背景与目标

现有 `/mccl-run` 流水线的 `mccl-tester` 只跑 2 个固定场景（场景A非对称、场景B对称）、各跑一次，出单次验证报告。两个痛点：

- **②**：没有场景矩阵、没有多轮统计、没有模板化报告。每次性能评估靠人工编辑文档。
- **⑤**：改动前后没有自动对比——想知道"这次改动让带宽涨了还是跌了"，得手动跑两遍、手动对数字。

本子系统新增一条独立流水线 `/mccl-bench`，AI 推断场景矩阵、多轮统计、可选前后对比、固定模板填数生成报告。与 `/mccl-run` 并存、互不干扰。

### 平台位置

7 子系统里②⑤在①之后：依赖①的 `mccl-prober` 门禁（bench 跑前先验环境就绪）。③（skill同步）、④（影响驱动验证）、⑥⑦（查找排队+定时）与本子系统正交。

## 2. 范围边界

**做：**
- 新增 `/mccl-bench` 编排命令，与 `/mccl-run` 并存
- AI 读 change.patch + 任务描述推断场景矩阵（planner）
- 按矩阵对每份 .so 跑 N 轮、聚合 mean/min/max（runner）
- ⑤前后对比：`--compare` 开关，双编译 before/after 两份 .so
- 固定 Markdown 模板填数生成报告（reporter）
- supervisor 审场景覆盖率 + 数字出处

**不做（YAGNI）：**
- 不动现有 `/mccl-run` 流水线（低回归风险）
- 不做基线缓存（v1 每次⑤多编一份旧库；缓存留后续）
- 不做自适应轮次收敛（默认1轮、`--rounds N` 显式多轮）
- 不新建配置文件（从 mccl-env.json 取主机IP，沿用①）
- 不做④（影响驱动验证）、⑥⑦（排队定时）、③（skill同步）

## 3. 核心约束

### 3.1 新增流水线，不替换现有

`/mccl-bench` 与 `/mccl-run` 并存。`/mccl-run` 保持"2场景单次验证"不变，服务于 commit 决策。`/mccl-bench` 服务于性能评估/对比，是采数流水线，不是验证闭环。

### 3.2 AI 推断 + 审计兜底

planner 读 change.patch 推断场景矩阵。AI 推断不确定、难复现，靠两条兜底：
- **选择理由必填**：bench-plan.md 每个选/不选的场景都要写理由，让监督员能审计覆盖率
- **supervisor 审计**：bench checklist 含"场景覆盖率"项，监督员读 change.patch 核对 planner 的理由是否成立

### 3.3 复用现有件，新增两件

复用 `mccl-developer`（扩双编译）、`mccl-reporter`（填模板）、`mccl-supervisor`（新 bench checklist）、`mccl-prober`（①门禁）。新增 `mccl-bench-planner`、`mccl-bench-runner`。

### 3.4 ⑤前后基线 = HEAD 干净态

"前" = `HEAD`（最后提交，干净基线），"后" = 工作区改动。因为改动通常在工作区未提交，"前"是提交前干净态。双编译：stash→checkout HEAD→编旧→stash pop→编新。不用 HEAD~1。

### 3.5 默认1轮，opt-in 多轮

默认 `--rounds 1`（与现有一致，省钱）。`--rounds N` 显式多轮，多轮时算 mean/min/max。1轮无统计意义（单点），符合预期。

### 3.6 报告 = 固定模板填数

模板 `references/bench-report-template.md` 入库（结构稳定、可静态校验）。reporter 禁 Bash、只读日志+stats 填数——契合"模板填数"，且沿用"禁Bash防报告造假"隔离。

### 3.7 bench 是采数，不是验证闭环

runner 部分失败（某轮 hang）跳过、继续其他、报告标"未覆盖"。不像 mccl-run 要求全绿——采数价值在"有多少算多少"。bench 不设外层 attempt（不是"改代码→验证"闭环，是"采数→出报告"）。

## 4. 组件

### 4.1 `mccl-bench-planner`（AI 推断场景矩阵）

**frontmatter**：
```yaml
---
name: mccl-bench-planner
description: 性能测试场景规划员。读 change.patch+任务描述，AI推断场景矩阵，写 bench-plan.md（矩阵+选择理由）。不编译、不跑测试。
tools: Read, Write, Grep, Glob, Bash
---
```

**输入**：`change.patch`（改动）+ 任务描述。
**职责**：读改动影响的代码路径（对称/非对称/FC kernel/…），推断该跑哪些场景。场景维度从现有 tester 参数空间取：

| 维度 | 取值 | 来源 |
|---|---|---|
| 二进制 | `$MCCL_PERF_BIN_ASYM` / `$MCCL_PERF_BIN_SYM` | mccl-env.json |
| 消息尺寸 | `-b <size> -e <size> -f <factor>`（如 1k/8k/1M/8M 全扫） | 推断 |
| `-R` | 无 / `-R 2`（对称变体） | 推断 |
| op/dtype | `-o sum -d float`（默认）/ 其他 | 推断 |

**产物 `bench-plan.md`**：
- **改动影响分析**：改了哪些路径（对称/非对称/两者）
- **场景矩阵**：要跑的单元格列表（每格 = 一组参数组合 + scenario_id）
- **选择理由**：为什么选这些、为什么排除其他——**这是监督员审计覆盖率的依据**，不写理由等于没选
- **对比基线声明**：⑤模式下声明"前"=`HEAD`（干净基线）、"后"=工作区改动

**审计约束**：planner 不得静默跳过场景。凡排除必写理由（如"改的是非对称路径，-R 2 对称变体不跑"）。监督员读 change.patch 核对理由是否成立。

### 4.2 `mccl-bench-runner`（多轮执行 + 聚合）

**frontmatter**：
```yaml
---
name: mccl-bench-runner
description: 性能测试执行员。按 bench-plan.md 矩阵对每份.so跑N轮，聚合mean/min/max，写原始日志+bench-stats.json。不改代码、不编译、不分发。
tools: Read, Write, Grep, Glob, Bash
---
```

**输入**：`bench-plan.md`（矩阵）+ 已编译分发的 .so（before/after 两份，⑤模式）。
**职责**：对每份 .so、每个场景单元格、跑 `--rounds N` 轮（默认1），每轮一次 mpirun。聚合 stats。

**每轮产物**：`bench-<so-tag>-<scenario-id>-round<r>.log`（原始 mpirun 输出，不摘要）。
**聚合产物 `bench-stats.json`**：
```json
{
  "so_tag": "after",
  "scenarios": [
    {"id":"sym-1k","bin":"...","params":"-b 1k -e 1k -f 2 -R 2",
     "rounds":3,
     "metrics":{"algbw_GBs":{"mean":95.2,"min":94.1,"max":96.0},
                "busbw_GBs":{"mean":180.0,"min":178.0,"max":182.0}}}
  ]
}
```
**硬约束**：不改代码、不编译、不分发（只跑 mpirun 采数）；日志必须原始输出；hang 处理同 mccl-tester（5分钟禁重启，采 dmesg+IB 写 anomaly 后跳过该轮继续其他）。

### 4.3 `mccl-developer` 扩展（双编译）

现有 developer 做单次"改→编→分发"。⑤ 需双编译：
1. `git stash` 工作区改动 → `git checkout HEAD`（干净基线）→ rsync → 编译 → 存 `libmccl.so.before` → 分发
2. `git stash pop` / `git checkout` 回工作区改动 → rsync → 编译 → 存 `libmccl.so.after` → 分发
3. 两份 .so 都分发到全部节点（不同文件名区分，runner 按文件名切换加载）

**关键**：基线编译用 `HEAD`（最后提交），不是 HEAD~1——改动通常在工作区未提交，"前"=提交前干净态，"后"=工作区改动。两份 .so 都走完整分发+md5 核对。纯②模式（不带 --compare）只编 after 一份。

### 4.4 `mccl-reporter` 填 bench 模板

reporter 禁 Bash、只读日志填数——契合"固定模板填数"。读 `bench-stats.json` + 原始日志，按 `references/bench-report-template.md` 填：
- 每场景的 before/after 带宽/延迟对比表
- 变化率%（after vs before）
- 异常项标注（回归>阈值标红）
- 证据索引（每个数字指向哪份日志）

### 4.5 `mccl-supervisor` + bench checklist

复用 supervisor agent，新增 `references/supervisor-checklists/bench.md`：
- planner 的场景选择理由是否成立（读 change.patch 核对）
- 是否有静默跳过的场景（理由缺失 = REWORK）
- bench-stats.json 每个数字能否在原始日志找到出处
- 报告结论是否与 stats 一致
- runner 是否发生未上报的 hang

### 4.6 `/mccl-bench` 编排

```
/mccl-bench <任务描述> [--rounds N] [--compare]
  planner -> bench-plan.md
  prober 门禁 (READY 才继续，复用①；NOT_READY/error 停，不编不跑)
  developer 双编译分发 (--compare: before+after; 纯②: 只after)
  runner 对每份.so按矩阵跑N轮 -> bench-stats.json
  reporter 填模板 -> bench-report.md
  supervisor(bench) 审: 场景覆盖率 + 数字出处
```

`--compare` 启用⑤前后对比（双编译）；不带则纯②（只跑当前 .so 的矩阵+多轮）。默认 `--rounds 1`。

## 5. 数据流（⑤ compare 模式）

```
/mccl-bench <任务> --compare --rounds 3
  └─> mccl-bench-planner
        读 change.patch + 任务描述
        => bench-plan.md (场景矩阵 + 选择理由 + 基线声明)
  └─> mccl-prober 门禁 (READY 才继续；NOT_READY/error 停，不编不跑)
  └─> mccl-developer (双编译)
        ① git stash → checkout HEAD → rsync → 编 → 存 libmccl.so.before → 分发
        ② checkout 工作区改动 → rsync → 编 → 存 libmccl.so.after → 分发
        => build.log + 两份 .so md5
  └─> mccl-bench-runner
        对 before & after 各跑矩阵×N轮
        => bench-<tag>-<scenario>-round<r>.log (原始) + bench-stats.json
  └─> mccl-reporter
        读 bench-stats.json + 原始日志
        按 references/bench-report-template.md 填
        => bench-report.md
  └─> mccl-supervisor(bench)
        审场景覆盖率 + 数字出处
        PASS/REWORK/ABORT
```

纯②模式（不带 `--compare`）：跳过双编译的"前"分支，developer 只编 after 一份，runner 只跑 after，reporter 出单库统计报告（无对比列）。

## 6. run 目录布局

```
.mccl-bench/<YYYY-MM-DD-HHMM>/
├── bench-plan.md              # planner 产出（矩阵+理由）
├── gpu-verdict.json           # prober 门禁产物（复用①）
├── before/
│   ├── build.log              # 基线编译日志
│   ├── libmccl.so.before.md5
│   └── bench-*.log            # runner 跑 before 的原始日志
├── after/
│   ├── build.log
│   ├── libmccl.so.after.md5
│   └── bench-*.log
├── bench-stats.json           # runner 聚合（before+after 各自 stats）
├── bench-report.md            # reporter 填模板产出
├── verdict-bench.md           # supervisor 判决
└── timeline.md
```

## 7. 错误处理

| 情况 | 动作 | 理由 |
|---|---|---|
| prober 门禁 NOT_READY | 停，不编不跑 | 复用①：环境没就绪别浪费双编译 |
| 基线编译失败（before） | 停，ABORT | 基线编不过说明环境/工具链问题，不是改动问题；继续编 after 无意义 |
| after 编译失败 | 停，ABORT | 同现有 developer：5轮内循环不过则停 |
| runner 某场景某轮 hang | 采 dmesg+IB 写 anomaly，跳过该轮，继续其他 | bench 是采数，部分失败仍有价值，报告标"该轮未覆盖" |
| runner 全部轮次 hang | 停，ABORT | 整体跑不起来 |
| reporter 数字找不到出处 | 标"未覆盖" | 复用现有 reporter 铁律：摘不到就写未覆盖，不推断 |
| supervisor 判 REWORK | 打回对应角色 | 见打回目标区分 |

**打回目标区分**（沿用 mccl-run 哲学）：
- 场景覆盖率不足 → 打回 **planner**（重判矩阵）
- 编译/分发问题 → 打回 **developer**
- 数字/报告问题 → 打回 **reporter**（不重跑测试，数据是好的）

**重试上限**：planner 2轮、reporter 2轮（同 mccl-run 的报告内循环）；developer 编译内循环5轮。bench 不设外层 attempt（不是"改代码→验证"闭环，是"采数→出报告"）。

## 8. 测试策略

延续静态不变式 + 负向测试。`tests/check.sh` 加不变式：

- **17**：`commands/mccl-bench.md` 存在且引用 `mccl-bench-planner`/`mccl-bench-runner`/`mccl-developer`/`mccl-reporter`/`mccl-supervisor`/`mccl-prober`。
- **18**：`agents/mccl-bench-planner.md` frontmatter 完整、含 Bash、正文含"选择理由"必填字段提示（审计约束的静态守卫）。
- **19**：`references/bench-report-template.md` 存在（模板入库是 reporter 能填数的前提）。
- **20**：`bench-stats.json` schema 静态校验——planner/runner 引用的字段名在模板里闭环（避免 runner 写 `algbw_GBs` 模板读 `algBw`）。

每条配负向测试（破坏→FAIL→恢复）。

**诚实边界**（沿用现有）：远程执行（mpirun多轮、双编译分发、planner的AI推断质量）无法本地端到端验证。能验的：静态不变式、模板结构、stats JSON schema、agent frontmatter。planner 的 AI 推断质量只能在真实使用中靠 supervisor 审计 + 人工盯。

## 9. Known Limitations（待决项，不阻塞实现）

1. **AI 推断的不确定性**：planner 读 change.patch 推断场景，可能漏跑或误跑。靠"选择理由"+supervisor 审计兜底，但无法静态保证覆盖率。首次使用建议人工盯 planner 的 bench-plan.md。
2. **基线编译成本**：⑤每次对比多编一份旧 .so（+几分钟）。对快速迭代是开销。可后续加 baseline 缓存（沿用①的缓存思路），v1 不做。
3. **多轮无统计意义**：默认1轮算不出 mean/min/max（单点）。要统计就显式 `--rounds N`。
4. **`mccl-run.json` vs `mccl-env.json`**：req② 提到"mccl-run.json 中的主机IP"——实际配置文件是 `mccl-env.json`（`/mccl-run` 是命令名）。bench 从 mccl-env.json 取主机IP，沿用①的 prober。不新建配置文件。
5. **runner 部分失败**：某轮 hang 跳过、继续其他——bench 报告会标"部分未覆盖"。不像 mccl-run 要求全绿，因为采数价值在"有多少算多少"。
6. **远程行为未经端到端验证**：本仓库连不上远程节点，bench 远程执行（mpirun多轮、双编译分发）只能验静态不变式，首用建议人工盯一轮。

## 10. 实现件清单

| 件 | 路径 | 动作 |
|---|---|---|
| 编排命令 | `plugins/.../commands/mccl-bench.md` | 新增 |
| 场景推断 agent | `plugins/.../agents/mccl-bench-planner.md` | 新增 |
| 多轮执行 agent | `plugins/.../agents/mccl-bench-runner.md` | 新增 |
| 双编译扩展 | `plugins/.../agents/mccl-developer.md` | 改（加双编译分支） |
| 报告模板 | `plugins/.../references/bench-report-template.md` | 新增 |
| bench checklist | `plugins/.../references/supervisor-checklists/bench.md` | 新增 |
| 自检 | `plugins/.../tests/check.sh` | 加不变式17/18/19/20 + 负向测试 |
| 文档 | `README.md` | 追加"测试矩阵与前后对比"小节 |

## 11. 不做的事（YAGNI 边界）

- 不动现有 `/mccl-run`（新增流水线，低回归风险）
- 不做基线缓存（v1 每次多编一份，缓存留后续）
- 不做自适应轮次收敛（默认1轮、显式多轮）
- 不新建配置文件（从 mccl-env.json 取，沿用①）
- 不做④⑥⑦③（正交子系统）
