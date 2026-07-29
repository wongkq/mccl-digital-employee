# GPU环境探测器（子系统①）设计

日期：2026-07-29
状态：已确认，待实现
所属：MCCL数字员工平台 7 子系统之一（① GPU环境探测）。本 spec 只覆盖①，不覆盖②⑤⑥⑦④③。

## 1. 背景与目标

现有 `/mccl-run` 流水线的 `mccl-tester` 执行前 checklist（`test-preflight.md`）只核对 IP / `libmccl.so` md5 / `-np` / `-x` 环境变量 / 二进制可执行，**不核对 GPU 是否真的存在、健康、空闲、带宽达标**。因此 32 卡测试可能直接铺到 GPU 正忙或正在报错的节点上空跑一轮，浪费昂贵的集群时间。

本子系统①解决这一问题：在测试前加一道**GPU环境门禁**，复用已有的 `gpu_health_check.sh`（1390行，已能 SSH 发现 GPU、测 P2P/PCIe/HBM/跨机OM 带宽、带阈值、生成 `health_report`、`auto_deploy` 到远端），补齐"占用检测"与"是否满足指定测试场景要求"的结构化判定。

### 平台位置

7 个子系统里①是地基：②⑤（测试自动化+对比报告）、④（影响驱动验证）、⑥⑦（查找排队+定时任务）都依赖"环境是否就绪/空闲/达标"这一判定。①先把这块做成**可复用探测原语**，输出结构化 verdict，留给⑥⑦调度器消费。

## 2. 范围边界

**做：**
- 可复用探测原语：输入主机列表+拓扑+bin，输出结构化 `gpu-verdict.json`（READY/NOT_READY + 逐项证据）
- 作为 `/mccl-run` 每轮 attempt 的前置硬门禁
- 占用检测（任一卡有进程即占用，全部卡须空闲）
- 带宽/健康复用 `gpu_health_check.sh`，按 run 缓存
- 结构化 verdict 作为⑥⑦的复用契约

**不做（YAGNI，留给后续子系统或人工）：**
- 自动等待/排队：GPU 不空闲时门禁只判"现在能不能跑"，NOT_READY 即停。自动等待重试属于⑥。
- 占用白名单/按 PID 过滤：v1 用"有进程即占用"最严判定，预留收紧项不做。
- 场景库：不做②的完整"每场景一份要求文件"，拓扑/卡数/bin 从 `mccl-env.json` 取，带宽阈值复用 `gpu_health_check.sh` 内置常量。
- 不新增配置文件（沿用 mccl-env 从 bash 收敛成单一 JSON 的既有哲学）。

## 3. 核心约束

### 3.1 不新增配置文件

拓扑/卡数/bin 路径/ssh opts 全部取自 `mccl-env.json`（经 `bin/mccl-env-load.py` 加载，raw 14 键 + 派生 7 键）。带宽阈值复用 `gpu_health_check.sh` 内置常量。req①"支持指定命令 + bin 文件位置"的灵活性通过**调用时参数覆盖**满足（`--probe-cmd`/`--bin`），不落进配置文件。

### 3.2 只读不改

探测器沿用 `references/mccl-safety.md` 的硬约束：只做只读探测，**不杀进程、不改文件、不重启节点**。发现 GPU 被占用只如实上报，不尝试清理。这条要追加进 `mccl-safety.md`（见 §8）。

### 3.3 全量门禁 + 带宽按 run 缓存

门禁默认 `--mode full`：跑完整探测（拓扑/数量/健康/占用/带宽/bin就绪）。为避免同一 run 内多次 attempt 重复跑分钟级带宽（环境在 run 内不变，换 .so 不影响 GPU 硬件/带宽），带宽结果按 run 缓存，后续 attempt 带 `--reuse-bw` 复用。**占用每轮重查**（GPU 可能中途被人抢）。缓存失效条件：① 新 run 必重跑；② 用户 `--no-bw-cache` 强制重测。

### 3.4 占用判定

任一卡的 mx-smi 进程列表非空即判该卡占用。测试要求全部卡空闲，**任何一卡有进程 = NOT_READY**。最严判定，避免抢卡。已知风险（集群常驻监控/守护进程占某卡会恒 NOT_READY）写进 Known Limitations，预留白名单收紧项，v1 不做。

## 4. 组件

### 4.1 `bin/mccl-gpu-probe`（探测原语，⑥⑦的复用入口）

新增 bash 脚本，可执行。

**输入参数：**
- `--mode full|quick`：门禁默认 `full`（含带宽）；`quick` 只跑秒级检查（拓扑/数量/健康/占用/bin），不跑带宽
- `--hosts IP1 IP2...`：覆盖主机列表；缺省取 `mccl-env.json` 的 `MCCL_NODES`（经 loader）
- `--reuse-bw <dir>`：复用 `<dir>` 下的带宽缓存（同一 run 的后续 attempt）
- `--no-bw-cache`：强制重测带宽
- `--probe-cmd <cmd>` / `--bin <path>`：覆盖默认探测命令/bin 路径（满足 req① 可指定命令/bin）
- `--help`

**逐项检查**（每项产子判定 + 证据）：

| # | 检查 | 来源 | 新/复用 |
|---|---|---|---|
| a | 拓扑/数量：每节点可发现 GPU、卡数 == `MCCL_GPUS_PER_NODE`、节点数匹配 `MCCL_NNODES`、∈{1,4,8}×8 | `discover_gpus` + env | 复用现有 {1,4,8}×8 判定 |
| b | 健康/型号：GPU 可发现、型号跨节点一致；full 模式带宽达阈值 | gpu_health_check + 阈值常量 | 复用 |
| c | 占用：每机每卡 mx-smi 进程列表，任一卡有进程 = 占用，全部卡须空闲 | 新增 | **新** |
| d | 带宽（仅 full）：P2P/PCIe/HBM/跨机OM，结果按 run 缓存 | gpu_health_check | 复用 + **新缓存** |
| e | bin 就绪：`MCCL_PERF_BIN_ASYM`/`MCCL_PERF_BIN_SYM`/`MCCL_MPIRUN` 在 NODE0 存在且可执行 | env | 新增核对 |

**实现要点：**
- `gpu_health_check.sh` 不输出 JSON、退出码恒 0（pass/fail 在 `health_report.txt` 统计行 `FAIL_TESTS`/`ERROR_TESTS` 与 `full.log` 的 `[PASS]/[FAIL]` 标记里），结果存内部 bash 关联数组、顶层无 `BASH_SOURCE` 守卫（不能安全 source）。因此包装脚本走**子进程调用 + 解析 `health_report.txt` 统计行**路线。
- 定位 `gpu_health_check.sh`：优先 `$REPO_ROOT/gpu_health_check.sh`；缺失则报错，**不静默跳过带宽检查**（静默跳过 = 门禁形同虚设）。
- 子进程调用：`gpu_health_check.sh --hosts <MCCL_NODES> --no-deploy`（`--no-deploy` 防止 auto_deploy 递归）。

**输出 `gpu-verdict.json`**（⑥⑦的结构化契约，主控在流水线内只读 `verdict` 字段）：

```json
{
  "verdict": "READY | NOT_READY | error",
  "mode": "full",
  "topology": {"nnodes": 4, "gpus_per_node": 8, "mode": "OAM32", "ok": true},
  "hosts": [{"host": "...", "gpu_count": 8, "model": "MetaX C550", "ok": true}],
  "occupancy": {"all_free": false, "occupied": [{"host": "...", "gpu": 3, "procs": ["pid ..."]}]},
  "bandwidth": {"cached": false, "fail": 0, "error": 0, "warn": 1, "report": "./gpu_health_results_.../health_report.txt"},
  "bins": {"sym": {"ok": true}, "asym": {"ok": true}, "mpirun": {"ok": true}},
  "failures": ["10.x.x.x gpu3 被进程占用"],
  "evidence": {"health_report": "...", "logs": "..."}
}
```

**`verdict` 三态语义**：
- `READY`：全部检查通过（带宽 WARN 仍算 READY，只在 `failures[]` 标告警）
- `NOT_READY`：环境不满足（占用/带宽FAIL/bin缺/拓扑不符），脚本退出码 1
- `error`：探测自身出错（ssh 不通/mxvs 缺/工具异常），脚本退出码 2

**退出码**（脚本被独立调用时的契约，主控流水线内不依赖）：
- `0` = READY
- `1` = NOT_READY
- `2` = error

**脚本出错时 JSON 的兜底**：若探测自身在写 JSON 前就崩（如连不上 ssh、mxvs 完全缺失），脚本无法写出合法 `gpu-verdict.json`。此时 mccl-prober agent 捕获脚本退出码非 0 且 JSON 缺失/不合法，自行落盘一份 `{"verdict":"error", "failures":["<脚本退出码与stderr摘要>"]}` 作为兜底，保证主控永远能解析到合法三态字段。

**带宽判定松紧：**
- `FAIL/ERROR > 0` => NOT_READY
- `WARN > 0`（偏低但未失败）=> 仍 READY，但在 `failures[]` 标"带宽告警"供人工收紧

### 4.2 `agents/mccl-prober.md`（探测 agent）

frontmatter：
```yaml
---
name: mccl-prober
description: GPU环境探测员。跑 bin/mccl-gpu-probe 全量探测，写 gpu-preflight.md 与 gpu-verdict.json，路由 READY/NOT_READY。只读不改，不杀进程，不跑测试。
tools: Read, Write, Grep, Glob, Bash
---
```

正文必须包含：
1. **开工前**：锚定双根（`REPO_ROOT`/`TOOLKIT_ROOT`，与现有四个 agent 一致）+ `eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")"` + 读 `references/mccl-safety.md`（含新增的"探测器只读"条款）。
2. **调用契约**：主控传入 run 目录路径与 attempt；跑 `mccl-gpu-probe --mode full`，后续 attempt 带 `--reuse-bw <run>/.bw-cache`。
3. **产物**：读 `gpu-verdict.json`，写 `<run>/attempt-<attempt>/gpu-preflight.md`（逐项 ✅/❌ + 证据 + verdict），`gpu-verdict.json` 原样落盘。
4. **硬约束**：只读不改，不杀进程，不跑 mpirun/编译/改源码。发现 GPU 占用只上报。
5. **不做**：不做自动等待/排队（那是⑥）；NOT_READY 即如实落盘上报。

### 4.3 `commands/mccl-run.md`（编排接入，改）

在现有编排循环里 **supervisor(dev)=PASS 之后、mccl-tester 之前**插入门禁步骤：

```
Task(mccl-supervisor, stage=dev) -> verdict-dev.md  (既有)
  PASS
  └─> Task(mccl-prober)  -> gpu-preflight.md, gpu-verdict.json   ← 新增门禁
        v = 解析 gpu-verdict.json 的 verdict 字段（READY / NOT_READY / error 三态）
        READY     -> Task(mccl-tester)  (既有)
        NOT_READY -> 停，向用户报告 failures[]，不递增 attempt、不调 tester
        error     -> 停，报告探测自身出错
```

**门禁解析契约**：主控解析 `gpu-verdict.json` 的 `verdict` 字段（三态 `READY`/`NOT_READY`/`error`）。退出码（0/1/2）是脚本被独立调用（如⑥⑦调度器直接调）时的契约，主控在流水线内不依赖退出码、只读 JSON 字段--避免"脚本退出码与 JSON 字段不一致"时的二义性。

**为什么插在 dev 之后而不是测试前最末尾**：dev 已 PASS 说明代码改完且库已分发到位，此刻唯一剩余风险就是"GPU 环境是否就绪/空闲/达标"——这是铺 32 卡前的最后一道闸。插在 dev 内循环之前没意义（编译不占 32 卡），插在 tester 内部会破坏 tester"只跑测试"的单一职责。

**为什么不递增 attempt**：NOT_READY 根因是环境（GPU 被占/带宽挂了/bin 缺失），不是代码。让 developer 重改一轮是错的方向。停、报告用户、等环境恢复或人工干预后重跑同一 attempt。这正是需求⑥"避免因GPU繁忙导致任务频繁失败"在门禁层的体现。

## 5. 数据流

```
/mccl-run (attempt N, supervisor(dev)=PASS)
  └─> mccl-prober
        load mccl-env.json (拓扑/bin/ssh)
        run bin/mccl-gpu-probe --mode full [--reuse-bw <run>/.bw-cache]
           ├─ gpu_health_check.sh --hosts <MCCL_NODES> --no-deploy  (带宽/健康，或命中缓存)
           ├─ 占用检查 (mx-smi per host/gpu)                         (每轮重查)
           └─ bin 就绪核对
           => 写 gpu-verdict.json (READY/NOT_READY)
        写 <run>/attempt-N/{gpu-preflight.md, gpu-verdict.json}
  └─> 解析 verdict
        READY     -> 进 mccl-tester（既有流程）
        NOT_READY -> 停，向用户报告 failures（不递增 attempt、不调 tester）
        error     -> 停，报告探测出错
```

**产物落盘**（供监督员审计 + ⑥⑦复用）：
- `<run>/attempt-<attempt>/gpu-preflight.md`（人类可读，逐项 ✅/❌ + 证据）
- `<run>/attempt-<attempt>/gpu-verdict.json`（结构化契约）
- `<run>/.bw-cache/`（带宽缓存，跨 attempt 复用）
- `gpu_health_check.sh` 的 `health_report.txt` 作为 evidence（路径链入 verdict）

## 6. 错误处理

| 情况 | 探测器退出码 | mccl-run 动作 | 递增 attempt |
|---|---|---|---|
| 全绿 READY | 0 | 进 tester | 否 |
| NOT_READY（占用/带宽FAIL/bin缺/拓扑不符） | 1 | 停，报告 `failures[]`，等用户/等环境 | 否 |
| error（ssh 不通/mxvs 缺/工具异常，含脚本崩、JSON 缺失由 agent 兜底） | 2 | 停，报告出错信息 | 否 |
| `gpu_health_check.sh` 非零退出 | 视情况归 error(2) | 记为 evidence，归类到出错 | 否 |

**三态都不递增 attempt**——门禁是环境问题，不是代码问题，不该消耗开发重试预算。这与现有"报告 REWORK 不递增 attempt"同一逻辑（问题不在代码就不烧 attempt）。

## 7. 测试策略

延续现有"静态不变式 + 负向测试"模式，`tests/check.sh` 加 2 条不变式：

- **不变式14**：`bin/mccl-gpu-probe` 存在、可执行、`--help` 退出码 0 且输出含 `--mode`/`--hosts`/`--reuse-bw`。负向：改坏 help 输出确认 FAIL。
- **不变式15**：`agents/mccl-prober.md` frontmatter 完整、`tools` 含 Bash、不含 `git push`/`reboot`/改源码类动作（只读约束的静态提示）；`commands/mccl-run.md` 引用了 `mccl-prober`。负向：删掉引用确认 FAIL。

**行为验证的诚实边界**（沿用现有 README"已知限制"声明）：本仓库连不上远程节点，探测器的实际远程执行（mx-smi/带宽/占用判定）**无法端到端验证**，只能验静态不变式 + 本地解析 mock 的 `health_report.txt`。真实环境验证推迟到拷入 MCCL 仓库后人工盯一轮。

## 8. 安全约束变更

`references/mccl-safety.md` 追加一条：

| # | 禁令 | 违反后果 |
|---|---|---|
| 9 | 探测器（mccl-prober / bin/mccl-gpu-probe）只做只读探测，禁止杀进程、改文件、重启节点。发现 GPU 被占用只如实上报 | ABORT |

## 9. Known Limitations（待决项，不阻塞实现）

1. **占用判定精度**："有进程即占用"是最严判定。若集群有常驻监控/守护进程占着某张卡，门禁会恒 NOT_READY。预留"白名单进程/按 PID 过滤"作为未来收紧项，v1 不做。
2. **带宽解析脆弱性**：包装脚本解析 `gpu_health_check.sh` 的 `health_report.txt` 统计行 + `full.log` 的 `[PASS]/[FAIL]` 标记。该脚本输出格式若变，解析需同步。本设计标注此耦合点。
3. **GPU 不空闲时无自动排队**：门禁只判"现在能不能跑"，NOT_READY 就停。自动等待重试属于⑥（环境查找与排队），不在①范围。①只把 `gpu-verdict.json` 留成⑥能消费的契约。
4. **`gpu_health_check.sh` 当前是仓库根独立脚本、非插件内件**：包装脚本定位它优先 `$REPO_ROOT/gpu_health_check.sh`，缺失则报错，不静默跳过带宽检查。
5. **远程行为未经端到端验证**：本仓库连不上远程节点，探测器远程执行行为（mx-smi/带宽/占用）只能验静态不变式，首用建议人工盯一轮。

## 10. 实现件清单

| 件 | 路径 | 动作 |
|---|---|---|
| 探测原语 | `plugins/mccl-digital-employee/bin/mccl-gpu-probe` | 新增（bash，可执行） |
| 探测 agent | `plugins/mccl-digital-employee/agents/mccl-prober.md` | 新增 |
| 编排接入 | `plugins/mccl-digital-employee/commands/mccl-run.md` | 改（插门禁步骤 + 引用 mccl-prober） |
| 安全约束 | `plugins/mccl-digital-employee/references/mccl-safety.md` | 追加第9条 |
| 自检 | `plugins/mccl-digital-employee/tests/check.sh` | 加不变式14/15 + 负向测试 |
| 文档 | `README.md` | 追加"GPU环境门禁"小节 |

## 11. 不做的事（YAGNI 边界）

- 不做自动等待/排队（⑥的活，①只留 verdict 契约）
- 不做占用白名单/PID 过滤（v1 最严判定，预留收紧项）
- 不做场景库（②的活，①从 mccl-env.json 取拓扑/bin）
- 不新增配置文件（沿用单一 JSON 哲学）
- 不重写 `gpu_health_check.sh`（路线 A：复用已测引擎，只包一层）
