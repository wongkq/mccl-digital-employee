# 计划：测试完成后按模板生成 HTML 性能对比报告

日期：2026-08-22（第二轮：在 Excel 对比表基础上新增 HTML 报告）

## 需求

每次 `/mccl-test` 测试完成后，除 Excel 对比表外，再按《测试报告模版.html》生成 HTML 图表报告。同样**只统计实际测试的尺寸**（如 32K-32M），未测试的 1K/2K 不出现。

## 模版事实（已解析）

- Chart.js@4.4.1（CDN）折线图报告：标题 + 副标题（数据范围/模式/单位）+ 叙述性总结段 + 4 张图卡（时延对比、带宽对比、时延降低%、带宽提升%）+ 公式说明区。
- 数据在 JS 常量 `raw`：每行 13 列 `[size, OOP非对称时延, OOP对称时延, OOP时延降低%, OOP非对称带宽, OOP对称带宽, OOP带宽提升%, IP非对称时延, IP对称时延, IP时延降低%, IP非对称带宽, IP对称带宽, IP带宽提升%]`。
- 模板 4 张图只画 OOP 列（IP 数据在 raw 里备用）--保持原样。
- 公式说明区仍是"/ FC带宽"字样--沿用上一轮用户要求，改为"/ 非对称内存带宽"。

## 设计决策

1. **不新增第二个脚本**：解析、日志选择（retry 感知）、公式计算与 Excel 完全同一套逻辑。把 `bin/mccl-excel-stats.py` 改名为 `bin/mccl-data-report.py`，一次调用同时产出 `测试数据对比.xlsx` 与 `测试报告.html`（同一份选定的日志，来源一致）。
2. HTML 由 Python 字符串模板 + `json.dumps` 生成 `raw` 数组（None -> null，Chart.js 自动跳点）；样式/图表 JS 逐字复刻模板。
3. **总结段程序化生成、不编造**：从数据推导（测试范围、N 档中对称更优/更差的档数、时延降低与带宽提升的极值及其尺寸、最大尺寸档表现）；某场景缺失时如实写"对比未覆盖"。
4. 副标题的数据范围取实际首/末档标签；缺数侧写 null；表尾公式说明区附"数据来源"与校验失败说明（与 xlsx 表尾一致的可追溯口径）。
5. `mccl-reporter` 仍保持无 Bash；HTML 与 xlsx 一样由 `/mccl-test` 主控在 §5.5 调脚本生成。
6. Chart.js 走模板原样 CDN 引用；离线打开时图表不渲染（模板固有行为，README 注明，数字仍在 raw/总结里）。

## 改动清单

1. `bin/mccl-excel-stats.py` -> **改名 `bin/mccl-data-report.py`**：
   - 新增 `build_html(...)`：模板逐字复刻 + 占位替换（副标题、总结段、raw 数组、公式行改"非对称内存带宽"、数据来源/异常说明行）。文件名等动态文本经 `html.escape`。
   - `main()`：新增 `--html-out`（run-dir 模式默认 `<run-dir>/测试报告.html`；显式模式默认与 `--out` 同目录同名）；无数据退出码 3 时两个文件都不产。
   - 输出摘要打印两个产物路径。
2. `commands/mccl-test.md` §5.5/§6：脚本名更新，产物加 `测试报告.html`（退出码3口径不变：两个文件都不生成、如实告知）。
3. `tests/test-excel-stats.sh` -> **改名 `tests/test-data-report.sh`**：既有 47 条断言保留（xlsx 侧），新增 HTML 断言：
   - 生成成功、`raw` 行数=实测档数、含 `>32KB<` 等标签且不含 `>1KB<`/`>2KB<`；
   - raw 数值与 xlsx 同源一致（同一次调用产出）；null 处理（缺 sym 侧）；
   - 副标题含实际范围"32KB ~ 16MB"；公式行含"非对称内存带宽"、不含"FC带宽"；
   - 来源注记含 retry-2；无数据时两个文件都不产、退出码 3。
4. `tests/check.sh` 不变式 33：脚本名同步，加"`--html-out` 提及"与"commands 接入 `测试报告.html`"校验。
5. `README.md`：`/mccl-test` 会做/产物、run 目录布局、"怎么读产物"（新增 `测试报告.html` 条目：4 张 Chart.js 图 + 数据驱动总结段、只含实测尺寸、CDN 离线说明）、自检一节的脚本/单测名同步。
6. 重新生成仓库根预览：`测试数据对比-预览.xlsx` + `测试报告-预览.html`（真实 asym 样例 + 模拟 sym），供用户浏览器打开验收。

## 验证

- `bash plugins/mccl-digital-employee/tests/test-data-report.sh` 全过（xlsx 旧断言不回退 + HTML 新断言）。
- `bash plugins/mccl-digital-employee/tests/check.sh` 全过。
- 预览 HTML：用 python 解析抽取 `raw` 数组与真实样例日志逐数核对；渲染效果（Chart.js 图表）需用户浏览器确认（本环境无浏览器）。
- 不能验的（如实声明）：真实集群端到端、浏览器渲染、CDN 可达性。
