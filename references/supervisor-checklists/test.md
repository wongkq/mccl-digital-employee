# test卡点checklist（卡点2：覆盖度）

stage=test时使用。产物来源：`test-preflight.md`、`test-asymmetric.log`（场景A）、`test-symmetric.log`（场景B）、`test-result.md`、`test-anomaly.md`（如有）。审计原则见`.claude/agents/mccl-supervisor.md`第1节：只认证据，不认声明。

每条格式：检查项 → 怎么查 → 违反后果。

## 1. 执行前checklist是否逐条核对并记录在`test-preflight.md` → 否则REWORK

怎么查：读`test-preflight.md`，核对`.claude/agents/mccl-tester.md`第4节列出的六条（IP范围、`libmccl.so`四节点md5独立核对、`-np`/`-host`、`MCCL_P2P_LEVEL`与`MCCL_PCIE_BUFFER_MODE`、`btl_tcp_if_include`、场景A/B命令就绪）是否六条都在，每条是否写明了具体的核对方式与结果（而不是笼统一句"已核对"）。任一条缺失或只有结论没有核对过程，判REWORK。

## 2. 场景A是否跑了（`test-asymmetric.log`存在且非空）→ 否则REWORK

怎么查：用Bash确认run目录下`test-asymmetric.log`存在，且文件非空（`wc -l`或文件大小大于0，且内容不是仅有一行占位文字）。场景A是回归保护，不是可选项——即使`dev-change.md`只提到对称内存改动，本项检查同样适用，不因改动范围而豁免。

## 3. 场景B是否跑了（`test-symmetric.log`存在且非空）→ 否则REWORK

怎么查：同上，针对`test-symmetric.log`。

## 4. 测试命令是否与`mccl-env.sh`定义一致（`-np 32`、`-host`四节点`:8`、`btl_tcp_if_include`、三个`-x`环境变量）→ 否则REWORK

怎么查：从`test-result.md`摘录的"实际执行的完整mpirun命令"，或直接从两份日志开头找到实际执行的mpirun命令行，逐项核对：

- `-np`的值等于`$MCCL_NP`（32）
- `-host`的值逐字等于`$MCCL_HOST_SPEC`（四节点各`:8`）
- `-mca btl_tcp_if_include`的值逐字等于`$MCCL_TCP_IF_INCLUDE`
- 三个`-x`参数均出现且值正确：`MCCL_PCIE_BUFFER_MODE=1`、`MCCL_ENABLE_FC=1`、`MCCL_P2P_LEVEL=PXB`

任一项缺失或值不符，判REWORK。

## 5. 日志是否是原始输出而非摘要 → 否则REWORK

怎么查：检查`test-asymmetric.log`/`test-symmetric.log`是否含完整mpirun原始输出的特征（如逐rank的输出、perf二进制完整数据表），而不是"共32条结果（已省略）"、"..."这类摘要痕迹。文件明显偏短、含省略性措辞，即判定为摘要，REWORK。

## 6. 有无hang/SegFault未上报 → REWORK

怎么查：grep两份日志中`segfault`、`Segmentation fault`、进程未正常退出等迹象。若命中，核对`test-result.md`对应场景是否明确判定FAIL并注明命中的已知故障模式，`test-anomaly.md`（若属于hang场景）是否按`.claude/agents/mccl-tester.md`第5节要求记录了`dmesg`/IB状态与时间线。命中故障迹象但未在`test-result.md`/`test-anomaly.md`中体现，判REWORK。

## 7. 是否发生重启等禁止操作 → **ABORT**

怎么查：`test-anomaly.md`、`test-result.md`、两份日志中是否有重启节点、Ctrl-C后重新发起mpirun、kill掉hang进程再重跑等描述。对照`references/mccl-safety.md`第3条核实。一旦发现此类操作的痕迹，直接ABORT。

## 8. 是否改了代码或库 → **ABORT**

怎么查：确认run目录下本阶段没有出现新的`change.patch`或对`libmccl.so`的写入记录（测试子代理不应产出改动）；`test-result.md`、`test-anomaly.md`、日志中若出现"重新编译"、"替换了库"、"改了源码"之类的描述，判定违反，直接ABORT。
