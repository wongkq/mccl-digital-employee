# 计划：测试完成后按模板生成 Excel 数据对比表

日期：2026-08-22

## 需求

每次 `/mccl-test` 测试完成后，把 `test-asymmetric.log`（场景A，非对称内存）与 `test-symmetric.log`（场景B，对称内存）的 perf 数据按 `测试数据对比模版.xlsx` 的版式统计成 Excel。**只统计实际测过的尺寸**（日志里出现的尺寸，如 32K–16M），未测试的 1K/2K 等不得出现。

## 已确认的事实

- 日志格式：nccl-tests 风格，每个尺寸一行，含 out-of-place 与 in-place 两组 `time(us) algbw(GB/s) busbw(GB/s) #wrong`（见仓库根的 `test-asymmetric.log` 样例，行 42-51）。
- 带宽口径：**busbw**（用户确认）。
- 模板公式（已用模板示例数据数值验证）：
  - `时延降低(%) = (非对称时延 - 对称时延) / 非对称时延 × 100`
  - `带宽提升(%) = (对称带宽 - 非对称带宽) / 非对称带宽 × 100`（即 FC带宽=非对称内存带宽）
  - 正数绿色、负数红色（模板说明行原文）。
- 运行环境无 openpyxl 且不可 pip 安装 -> 脚本必须**纯标准库**（zipfile + 手写 SpreadsheetML XML）。

## 设计决策

1. **`mccl-reporter` 保持无 Bash**（不变式8 的物理隔离不动）。Excel 由新增脚本生成，`/mccl-test` 主控（有 Bash）在报告写完后调用。
2. **脚本从零生成 xlsx**（不改模板文件本身）：布局逐格复刻模板（合并单元格、表头、行 23-27 说明文字、列宽、边框、正绿负红），数据行动态生成。
3. **行集合 = 两场景日志实际解析出的尺寸的并集**，升序排列；某场景缺某尺寸时该侧单元格留空、% 列留空；整场景日志缺失时该场景 4 列全空并加说明。两日志都没有尺寸时（没跑成测试）不生成空表、非零退出。
4. **重试感知**：run 目录模式下，某场景存在 `test-*.retry-<k>.log` 时取最大 `k` 的那份（`mccl-tester` 规定"最终判定以最后一次执行为准"），否则用首次 `test-*.log`。表尾注明数据来源文件名（可追溯）。
5. `#wrong != 0` 的行照常填数，但表尾说明列出哪些尺寸校验失败。

## 改动清单

### 1. 新增 `plugins/mccl-digital-employee/bin/mccl-excel-stats.py`（可执行）

纯标准库 Python3。CLI：

```
mccl-excel-stats.py --run-dir <dir> [--out <xlsx>]      # 自动选最终日志
mccl-excel-stats.py --asym <log> --sym <log> --out <xlsx>  # 显式指定（测试/手动用）
```

- 解析正则（对齐真实样例）：`size count type redop root  oop_time oop_algbw oop_busbw oop_wrong  ip_time ip_algbw ip_busbw ip_wrong`，按 size 存 `{'oop':(time,busbw), 'ip':(time,busbw), 'wrong':bool}`。
- 尺寸标签复刻模板写法：`1KB..64KB, 128K, 256K, 512K, 1MB..32MB`（查表覆盖 2^10..2^25，非标准尺寸回退 `NKB/NMB` 通用格式）。
- 数值：时延/带宽取日志原值、写 `0.00` 数字格式；% 列计算后保留 2 位。
- xlsx 产出：`[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`(+rels)、`xl/styles.xml`、`xl/worksheets/sheet1.xml`，字符串用 inlineStr（免 sharedStrings 记账）。sheet 名 `综合对比`。
- 版式：A1:A4 `数据大小`、B1:G2 `Out-of-place`、H1:M2 `In-place`、行3-4 两级表头（非对称内存/对称内存/时延降低(%)、带宽(GB/s)×2/带宽提升(%)）、行5起数据、隔一空行后放说明区（模板行23-27原文 + 数据来源行 + 异常说明行）。正数%绿字、负数%红字、0 黑字，表格细边框。
- 退出码：0=生成成功；2=参数错；3=没有任何可解析数据（不产文件）。

### 2. 修改 `plugins/mccl-digital-employee/commands/mccl-test.md`

- 新增 **§5.5 生成 Excel 数据对比表**：reporter 完成后主控执行
  `python3 "$TOOLKIT_ROOT/bin/mccl-excel-stats.py" --run-dir "$RUN_DIR" --out "$RUN_DIR/测试数据对比.xlsx"`。
  成功则继续；退出码 3（测试根本没跑、无日志）时如实告知用户不生成表，不视为流程失败（结论以 report 为准）。
- §6 收尾：输出的绝对路径清单加入 `测试数据对比.xlsx`。

### 3. 新增 `plugins/mccl-digital-employee/tests/test-excel-stats.sh`

仿 `test-bench-stats.sh`（assert_eq 风格），fixture 用净化过的样例日志格式（**不含真实私网IP**）：

1. 双场景日志（32K–16M）→ 生成成功；sheet XML 含 `32KB..16MB` 标签、**不含** `1KB/2KB/4KB/8KB/16KB`；含预计算的时延降低%/带宽提升% 期望值；XML 可被 ElementTree 解析、合并单元格齐全。
2. run-dir 重试选择：`test-symmetric.log` + `retry-1` + `retry-2` → 取 retry-2 的值，来源注记含 `test-symmetric.retry-2.log`。
3. 缺 sym 日志 → 仍生成，sym 侧空白 + 缺失说明。
4. 尺寸不对齐（asym 32K–16M、sym 仅 1M–16M）→ 32K 行存在、sym 侧空。
5. 两日志全缺 → 退出码 3、不产生文件。

### 4. 修改 `plugins/mccl-digital-employee/tests/check.sh`

新增不变式 #15：`bin/mccl-excel-stats.py` 存在、可执行、`--help` 退出码 0 且提及 `--run-dir/--asym/--sym/--out`；脚本内不得引用 `MCCL_` 环境变量（保持不变式7的引用闭合）。

### 5. 修改 `README.md`

- `/mccl-test` 一节的"会做/产物"与 run 目录结构树、'怎么读产物'加入 `测试数据对比.xlsx`（说明：只含实际测试尺寸，来源日志在表尾注明）。
- 角色表不新增行（脚本是主控调用的工具，不是子代理）。

## 不改的东西

- `mccl-reporter.md`（保持无 Bash 物理隔离）、`mccl-tester.md`、`mccl-env.json.example`（无新环境键）。
- 模板文件本身只作版式参考，运行期不依赖它。

## 验证

本仓库无真实集群，能验的（全部要做）：
- `bash plugins/mccl-digital-employee/tests/test-excel-stats.sh` 全过（含"未测尺寸不出现"的负向断言）。
- `bash plugins/mccl-digital-employee/tests/check.sh` 全过（含新不变式 #15，且不动坏既有 14 条）。
- 用真实样例 `test-asymmetric.log` 手动生成一次 xlsx，解包检查 XML 结构、合并单元格、数字与样例逐一对得上。
- 生成的 xlsx 在无 Excel 的环境下做结构校验（zipfile 可开、XML 良构、Content_Types 完整）；"Excel/WPS 能打开"需用户在真实环境点开确认，README 注明。

不能验的（如实声明）：真实多节点跑完一轮 `/mccl-test` 后的端到端产出、WPS/Excel 的渲染效果。
