# bench卡点checklist（场景覆盖率 + 数字出处）

stage=bench时使用。产物来源：`bench-plan.md`、`bench-stats.json`、`bench-*.log`（原始）、`bench-report.md`。审计原则见 `mccl-supervisor.md` 第1节：只认证据，不认声明。

每条格式：检查项 → 怎么查 → 违反后果。

## 1. planner 的场景选择理由是否成立 → 理由缺失或不成立 REWORK

怎么查：读 `bench-plan.md` 的"选择理由"字段。每个要跑的场景写了为什么选、每个排除的场景写了为什么不跑。理由缺失（只列场景不给理由）= REWORK。再读 `change.patch` 核对理由是否与实际改动匹配——如 change.patch 改了 `registerSymetricBuffers`（对称路径），planner 却写"只跑非对称，排除 -R 2"，理由与改动矛盾 = REWORK。

## 2. 是否有静默跳过的场景 → REWORK

怎么查：`bench-plan.md` 的场景矩阵是否覆盖了改动影响面。若 change.patch 涉及两条路径共用的 host 代码，planner 只选了一条路径的场景、且未声明另一条"不跑的理由"，判 REWORK。静默跳过 = 没写理由就排除。

## 3. bench-stats.json 每个数字能否在原始日志找到出处 → 找不到 REWORK

怎么查：抽 1-2 个 scenario 的 metrics 值，去对应的 `bench-<tag>-<scenario_id>-round-<r>.log` 里 grep 该数值。stats 里的 mean/min/max 必须能从原始日志的 perf 输出行反推（mean 是各轮的均值、min/max 是极值）。找不到对应原始数据 = REWORK。

## 4. 报告结论是否与 stats 一致 → 不一致 ABORT

怎么查：`bench-report.md` 的"性能数据"表与 `bench-stats.json` 逐项核对。reporter 写的数字在 stats 里找不到、或 stats 里有但报告漏了（非"未覆盖"理由），判 REWORK；reporter 称"无回归"但 stats 显示 after 比 before 跌幅>阈值却未在"异常项"标出 = ABORT（报告造假方向）。

## 5. runner 是否发生未上报的 hang → REWORK

怎么查：grep `bench-*.log` 中 segfault/hang 迹象。若命中，核对是否有对应 `bench-anomaly.md` 或报告"异常项"标注。命中故障迹象但未上报 = REWORK。发生重启等禁止操作 = ABORT（对照 `references/mccl-safety.md` 第3条）。

## 6. 是否改了代码或库 → ABORT

怎么查：bench 阶段不应出现新的 `change.patch`（planner 只读不写代码）。runner 不应编译/分发（那是 developer 的活）。发现 bench 阶段产出改动或重编库 = ABORT。

## 7. 拓扑合法性 → 不支持却跑了 ABORT

怎么查：核实 `$MCCL_NNODES`/`$MCCL_GPUS_PER_NODE`。不支持拓扑（非 1节点 且非 4/8节点×8卡）下仍跑了 mpirun 产出 bench-*.log = ABORT，同 test 卡点第9条理由。
