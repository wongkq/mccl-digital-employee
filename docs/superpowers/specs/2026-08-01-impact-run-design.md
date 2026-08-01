# 影响驱动验证（子系统④）设计

日期：2026-08-01
状态：已确认，待实现
所属：MCCL数字员工平台 7 子系统之五（④ 影响驱动验证/单元测试）。①②⑤⑥⑦③已完成。

## 1. 背景与目标

`/mccl-run` 是"改代码→编→跑固定 2 场景"——不管改了哪都跑同一对场景，也不问改了什么。改一行引号跑完整套是浪费；改一个影响居住的函数却没人告诉你会测到什么，缺少scope→影响→测试的对应关系。

④ 提供一条 **scope 驱动** 的验证链：用户补上 `--scope=<涉及文件/模块>` → AI 读 scope + diff → 产出「受影响功能、建议测试场景 + 建议部署位置」冻结建议 → 用户批准/微调/取消 → 再进入现成编译/门禁/测试/判定。

- **手工 scope 先行**：`--scope` 命令行参数，路径/模块清单由用户提供
- **AI 给冻结建议**：planner agent 综合分析后产出 impact-plan.md，并展示给你：**受影响功能**、**调用方**、**建议场景**、**建议部署目标**。你批准/微调/取消
- **后续复用**：编译复用 `mccl-developer`；环境门禁复用 `mccl-prober`；测试跑受影响场景的复用现成 runner；判定权仍归 `mccl-supervisor`

## 2. 范围边界

**做：**
- 新增 `agents/mccl-impact-planner.md`（影响分析 agent）
- 新增 `commands/mccl-impact-run.md`（指挥调度命令，排谁先后跑谁）
- 命名分界：主控调度放在 `commands/`；**不**新增新主控文档子代理（using 现有 agents/mccl-* 复用编译/门禁/测试能力）
- check.sh 加不变式 26/27与 �匀兴负向测试
- spec + plan + README 小节

**不做（YAGNI）：**
- 不自动 scope（不定 AI 从 `git diff` 猜 scope 而不经你确认）——3c 决策：手工 scope 先行
- 不改 `mccl-run`/`mccl-bench` 主控编排——④ 是**独立薄层**，在原流水线上插前置不渡动原来流水线的任何文档子代理
- 不支持多主机目标集——部署目标只选 `MCCL_NODE0_IP`，浪费心情前置跨节点的分发
- 不做 bench 多轮——跑被判定到受影响的场景**一次**，与载 `/mccl-run verification` 同粒度

## 3. 核心约束

### 3.1 scope 是用户提供的，不是 AI.choice猜到的
2 决策（3c）：手工 scope 先行。没有 `--scope` → 报错提示并停，不会猜。AI 的活是把 scope 里的 diff 读懂，再把**受影响功能/调用方/建议测试/建议部署**标注给你看。

### 3.2 影响分析是产出物，不是私有思维过程
planner agent 产出 `impact-plan.md`（落盘检阅）+ tabindex 内容给你看。你不点头，后续的动作generator 不做。批淮是命令式的（你说"OK/调整/取消"），不是猜测。

### 3.3 复用不重构
④ 不新增任何编译/门禁/测试/判定的子代理代码。指挥调度只负责先后跑谁：**影响分析 → 用户批准 → developer → prober → runner → supervisor**。原主控文档子代理，`mccl-run`/`mccl-bench` 的编排，不动。

### 3.line附属性4 scope 缺省就是报错停
没 `--scope` → 告诉你用法并停。不是帮你默认/不是让 AI 猜 scope。

### 3.5 验证粒度是受影响场景的一次运行
跑被判定到受影响的场景**一次**（与 `/mccl-run verification` 同粒度），不是 bench 多轮统计。功能性验证，不是性能回归。

## 4. 组件

### 4.1 `agents/mccl-impact-planner.md`（影响分析 agent）

frontmatter: `tools: Read, Write, Grep, Glob, Bash`

收到的参数：`--scope=<文件/模块清单>`（必须）、可选描述。
- 解析 scope（支持 promitt文件`src/hw/symm.c`、`src/hw/`、混合清单）
- 跑 `git diff`（scope 限定）、`git status`，读 scope 里的 facts
- 产出 `<RUN_DIR>/impact-plan.md` + 展示中文冻结建议表格：
  | 涉及模块 | 受影响功能 | 调用方 | 建议测试场景 | 建议部署位置 |
- 问你：OK / 调整 / 取消。OK 后把 impact-plan 交回主控；调整则按修改内容重出；取消则停。

### 4.2 `commands/mccl-impact-run.md`（指挥调度命令）

主控编排：planner → approve → developer → prober → runner → supervisor。调用现有 subagent：
1. `Task(mccl-impact-planner)`：传 scope/desc/run_dir → impact-plan.md + 冻结建议
2. impact-plan 批准后 `Task(mccl-developer)` 编译产出 .so
3. `Task(mccl-prober)` 门禁：READY/NOT_READY/error
4. READY 后 `Task(mccl-bench-runner)`（受影响场景跑）
5. `Task(mccl-supervisor, stage=test)` verdict

**attempt 语义**：REWORK 打会到 planner（scope 理解错就重考虑），不打会到 developer——scope 错了就先重考虑，不负责重编译的浪费。

## 4.3 check.sh 不变式 26/27

- **26**：`agents/mccl-impact-planner.md` 存在，且正文含 `impact-plan`、`--scope`、`**冻结建议**` 三词
- **27**：`commands/mccl-impact-run.md` 存在，且正文含 `planner`、`--scope`、或 `mccl-impact-planner` 至少其一

## 5. 数据流

```
用户: /mccl-impact-run "修了 symm 的一个 case" --scope=src/hw/symm,src/hw/slice_nic
  ├─ Task(mccl-impact-planner)
  │    git diff --scope + git status → impact-plan.md + 中文冻结建议表
  │    ➔ 你：OK / 调整 / 取消
  │ 调整: 重出建议；取消: 停；OK: 交调度继续
  ├─ Task(mccl-developer) 编译产出 .so（复用，不动代码）
  ├─ Task(mccl-prober) 门禁 READY/NOT_READY/error
  ├─ READY -> Task(mccl-bench-runner) 跑建议场景（炮结算）
  └─ Task(mccl-supervisor, stage=test) verdict
```

## 6. 状态文件布局

```
.mccl-runs/<ts>/attempt-<n>/
├── impact-plan.md         # planner 产出（受影响功能+建议场景+建议部署 ）
├── gpu-verdict.json         # prober 产出（复用）
├── test-result.md           # runner 产出（复用 runner格式）
└── verdict-test.md          # supervisor 判定（复用格式）
```

run_dir 沿用 /mccl-run 的习惯 attempt-N 布局，便于比对。impact-plan 由 planner 写，主控只读放行/拒绝标记（文件存在=PENDING人批准，不动不写）。

## 7. 错误处理

| 情况 | 动作 | 理由 |
|---|---|---|
| 缺 `--scope` | 报错用法并停 | 手工 scope 先行（3c 决策），不猜 |
| `git diff` scope 为空 | 给你看 scope 里有改动吗，你确认后再做下一步 | scope 错不等于 PASS，不等于 REWORK |
| planner 自崩/impact-plan 未落盘 | 停，不报"未批准" | planner 的事交给主控，不负责接下来 |
| 用户取消 | 停 | 取消是你的权利，不是失败 |
| prober 门禁 NOT_READY/error | 停，不递增 attempt；报 failures 给你 | 影响驱动是环境就绪后才开展的，同⑥⑦ |

## 8. 测试策略

**静态不变式**（tests/check.sh 加 26/27）：
- **26**：`agents/mccl-impact-planner.md` 存在且含 `impact-plan`、`--scope`、`**冻结建议**` 三词
- **27**：`commands/mccl-impact-run.md` 存在且含 `planner`、`--scope`、或 `mccl-impact-planner` 至少其一

**负向测试**：每一条不变式配破坏->FAIL->恢复（删 impact-plan / scope / planner 关键字 → FAIL）。

**诚实边界**：planner 的呢 shell 影响分析（AI 作用）无法本地验证；编排调度（主控先后跑谁）也无法本地验证。能验的：静态不变式、负向测试、check.sh 闭环。首用建议人工盯一轮。

## 9. Known Limitations

1. **AI 建议猜的是"会测什么"不是"测得对不对"**：测试建议场景是 AI 根据 scope 猜的，可能漏/误。批准时你负责审 AI 的建议。
2. **跑一次不是回归**：受影响场景跑 **一次**，与 `/mccl-run verification` 同粒度；要 bench 多轮统计走 `/mccl-bench`。
3. **单目标部署**：只部署到 `MCCL_NODE0_IP`（编译节点）；跨节点分发后续小节再做。
4. **没有性能基线**：④ 是功能验证不是性能基线。5062对比走 `--compare`。

## 10. 实现件清单

| 件 | 路径 | 动作 |
|---|---|---|
| 影响分析 agent | `plugins/.../agents/mccl-impact-planner.md` | 新增
| 调度命令 | `plugins/.../commands/mccl-impact-run.md` | 新增
| 自检 | `plugins/.../tests/check.sh` | 加不变式 26/27 + 负向
| 主控编排 | ❌ 不动（复用现有 agents/runner; 不动 `mccl-run`/`mccl-bench` 主控文档子代理） |
| spec | `docs/.../2026-08-01-impact-run-design.md` | 新增 |
| README | README: 追加『影响驱动验证』小节 |

##6 不动的事（YAGNI 边界）
- 不改 `mccl-run`/`mccl-bench` 主控编排文档子代理
- 不自动 scope（不定 AI 从 `git diff` 猜 scope 而不经你确认）
- 不跨节点分发（编译节点不变，只编编译节点）
- 不做性能基线（走 `/mccl-bench --compare`）
