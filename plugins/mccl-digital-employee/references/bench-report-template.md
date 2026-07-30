# 性能测试报告（模板）

**说明**：这是 `mccl-reporter` 填数的目标模板。reporter 读 `bench-stats.json` + 原始日志，按本结构填，不得改动结构、不得补未覆盖的数字。`{{...}}` 是 reporter 替换的占位；找不到出处的写"未覆盖"。

## 1. 任务摘要
- 任务描述：{{任务描述}}
- 模式：{{纯② 单库统计 | ⑤ 前后对比}}
- 轮次：每场景 {{rounds}} 轮
- 基线声明（⑤模式）：前 = `HEAD`（干净基线），后 = 工作区改动

## 2. 改动影响分析
（来自 bench-plan.md，原样转述，不重新推断）
{{改动影响分析：对称/非对称/两者}}

## 3. 场景矩阵
（来自 bench-plan.md，列出跑的场景 + 选择理由）

| scenario_id | 二进制 | 参数 | 选择理由 |
|---|---|---|---|
| {{id}} | {{bin}} | {{params}} | {{理由}} |

## 4. 性能数据

### 4a. 单库统计（纯②模式 或 ⑤的 before/after 各自）
（metrics 键名固定 algbw_GBs / busbw_GBs，单位 GB/s，与 bench-stats.json 闭环）

| so_tag | scenario_id | rounds | algbw mean | algbw min | algbw max | busbw mean | busbw min | busbw max |
|---|---|---|---|---|---|---|---|---|
| {{after}} | {{sym-1k}} | {{3}} | {{95.2}} | {{94.1}} | {{96.0}} | {{180.0}} | {{178.0}} | {{182.0}} |

### 4b. 前后对比（仅⑤模式）
（变化率% = (after - before) / before × 100；回归>阈值标 ⚠️）

| scenario_id | before algbw | after algbw | 变化率% | before busbw | after busbw | 变化率% |
|---|---|---|---|---|---|---|
| {{sym-1k}} | {{95.0}} | {{95.2}} | {{+0.2}} | {{178.0}} | {{180.0}} | {{+1.1}} |

## 5. 异常项
- {{带宽回归>阈值 / hang跳过的轮次 / 未覆盖场景，逐条列；无则写"无"}}

## 6. 证据索引
每个数字指向原始日志文件名 + 行号/行范围。
- {{sym-1k after algbw mean 95.2}} ← `after/bench-after-sym-1k-round-1.log:42` 等

## 7. 结论
（采数完成度 + 是否有回归。bench 不判"可否commit"——那是 /mccl-run 的职责）
{{结论：如"3场景×3轮全部采到，无回归" 或 "sym-8k 第2轮 hang 跳过，该场景仅2轮数据"}}
