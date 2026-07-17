# test卡点checklist（卡点2：覆盖度）

stage=test时使用。产物来源：`test-preflight.md`、`test-asymmetric.log`（场景A）、`test-symmetric.log`（场景B）、`test-result.md`、`test-anomaly.md`（如有）。审计原则见`.claude/agents/mccl-supervisor.md`第1节：只认证据，不认声明。

每条格式：检查项 → 怎么查 → 违反后果。

## 1. 执行前checklist是否逐条核对并记录在`test-preflight.md` → 否则REWORK

怎么查：先核实`test-preflight.md`里记录的`$MCCL_NNODES`值走的是哪个子表。多节点模式（`$MCCL_NNODES=4`或`8`）核对`.claude/agents/mccl-tester.md`第4a节列出的六条（IP范围、`libmccl.so`各节点md5独立核对、`-np`/`-host`、`MCCL_P2P_LEVEL`与`MCCL_PCIE_BUFFER_MODE`、`btl_tcp_if_include`、场景A/B命令就绪）是否六条都在；单节点模式（`$MCCL_NNODES=1`）核对第4b节列出的四条（IP范围、容器内md5核对、`-np`与`--mca plm isolated`、二进制可执行）是否四条都在。每条是否写明了具体的核对方式与结果（而不是笼统一句"已核对"）。任一条缺失或只有结论没有核对过程，判REWORK。

## 2. 场景A是否跑了（`test-asymmetric.log`存在且非空）→ 否则REWORK

**先核实`$MCCL_NNODES`（读`mccl-env.sh`或run目录里能核实到的值），本条与第3条只适用于多节点模式（`$MCCL_NNODES=4`或`8`）。** 单节点模式（`$MCCL_NNODES=1`）不产出场景A/B日志，改判见本条末尾的"单节点模式"分支，不得因为没有`test-asymmetric.log`就机械判REWORK。

多节点模式下，怎么查：用Bash确认run目录下`test-asymmetric.log`存在，且文件非空（`wc -l`或文件大小大于0，且内容不是仅有一行占位文字）。场景A是回归保护，不是可选项——即使`dev-change.md`只提到对称内存改动，本项检查同样适用，不因改动范围而豁免。

**单节点模式**：改查`test-singlenode.log`是否存在且非空，同时核对`test-result.md`是否**显式声明了覆盖度**——见第3条。`test-asymmetric.log`/`test-symmetric.log`在单节点模式下不应存在，不存在不算缺失。

## 3. 场景B是否跑了（`test-symmetric.log`存在且非空）→ 否则REWORK；单节点模式下改判覆盖度声明是否到位 → 漏了判REWORK

多节点模式下，怎么查：同第2条，针对`test-symmetric.log`。

**单节点模式（`$MCCL_NNODES=1`）**，本条改查`test-result.md`是否**显式写明**以下两点，缺一即判REWORK：

1. 本次是单节点冒烟，跨节点对称内存路径（`symMemoryMapLsaTeamExtended`、`bootstrapAllGather`、`37ba549`）**未执行**。
2. `info.rank % GROUP`的修复在单节点下不可区分（rank 0..7，`rank % 8 == rank`，改前改后行为一致），本次测试对该类bug**无诊断能力**。

**这条是本次拓扑可配置化改造的要害，比日志本身是否存在更重要**——漏了覆盖度声明，比测试没跑更危险：一份"跑通了、有perf数据"但没声明覆盖边界的`test-result.md`，会让人误以为对称内存的跨节点路径已经验证过。只要`test-preflight.md`/`test-result.md`任一处显示`$MCCL_NNODES=1`却对这两点只字不提或表述含糊（例如笼统写"本次为单节点测试"而不点名具体未覆盖的路径和bug类型），判REWORK，不得因为日志本身完整、perf数据齐全就放行。

## 4. 测试命令是否与`mccl-env.sh`定义一致 → 否则REWORK

**多节点模式**（`-np`、`-host`各节点`:8`、`btl_tcp_if_include`、三个`-x`环境变量）：

怎么查：从`test-result.md`摘录的"实际执行的完整mpirun命令"，或直接从两份日志开头找到实际执行的mpirun命令行，逐项核对：

- `-np`的值等于`$MCCL_NP`（4节点应为32，8节点应为64）
- `-host`的值逐字等于`$MCCL_HOST_SPEC`
- `-mca btl_tcp_if_include`的值逐字等于`$MCCL_TCP_IF_INCLUDE`
- 三个`-x`参数均出现且值正确：`MCCL_PCIE_BUFFER_MODE=1`、`MCCL_ENABLE_FC=1`、`MCCL_P2P_LEVEL=PXB`

任一项缺失或值不符，判REWORK。

**单节点模式**：从`test-result.md`或`test-singlenode.log`找到实际执行的mpirun命令行，核对：

- `-np`的值等于`$MCCL_NP`（应为8）
- 命令中出现`--mca plm isolated`
- 命令是在容器内执行的（`docker exec`上下文），不是宿主机层`-host`形态

任一项缺失或值不符，判REWORK。

## 5. 日志是否是原始输出而非摘要 → 否则REWORK

怎么查：检查`test-asymmetric.log`/`test-symmetric.log`是否含完整mpirun原始输出的特征（如逐rank的输出、perf二进制完整数据表），而不是"共32条结果（已省略）"、"..."这类摘要痕迹。文件明显偏短、含省略性措辞，即判定为摘要，REWORK。

## 6. 有无hang/SegFault未上报 → REWORK

怎么查：grep两份日志中`segfault`、`Segmentation fault`、进程未正常退出等迹象。若命中，核对`test-result.md`对应场景是否明确判定FAIL并注明命中的已知故障模式，`test-anomaly.md`（若属于hang场景）是否按`.claude/agents/mccl-tester.md`第5节要求记录了`dmesg`/IB状态与时间线。命中故障迹象但未在`test-result.md`/`test-anomaly.md`中体现，判REWORK。

## 7. 是否发生重启等禁止操作 → **ABORT**

怎么查：`test-anomaly.md`、`test-result.md`、两份日志中是否有重启节点、Ctrl-C后重新发起mpirun、kill掉hang进程再重跑等描述。对照`references/mccl-safety.md`第3条核实。一旦发现此类操作的痕迹，直接ABORT。

## 8. 是否改了代码或库 → **ABORT**

怎么查：确认run目录下本阶段没有出现新的`change.patch`或对`libmccl.so`的写入记录（测试子代理不应产出改动）；`test-result.md`、`test-anomaly.md`、日志中若出现"重新编译"、"替换了库"、"改了源码"之类的描述，判定违反，直接ABORT。

## 9. 拓扑合法性：`$MCCL_NNODES`不是1/4/8时，是否停止并上报 → 否则**ABORT**

怎么查：核实`$MCCL_NNODES`的值。若不是1、4、8三者之一：

- 检查`test-preflight.md`是否写明了`$MCCL_NNODES`的实际值与"不支持的拓扑"判定，且没有产出`test-result.md`、没有任何mpirun日志文件（`test-asymmetric.log`/`test-symmetric.log`/`test-singlenode.log`均不应存在）。
- 若测试子代理在拓扑不支持的情况下仍然跑了mpirun、产出了日志和`test-result.md`，视为闷头跑了不该跑的流程——**直接ABORT**，不给REWORK的机会。理由同dev卡点第12条：这种拓扑下对称内存路径不会真正启用，产出一份"看起来跑通"的报告比不跑更有害。

`$MCCL_NNODES`为1、4、8时，本条不触发，按其余各条正常审计。
