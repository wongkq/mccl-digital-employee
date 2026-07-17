# MCCL数字员工 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 产出一套可移植的Claude Code子代理定义，把MCCL的"改代码→编译→32卡测试→报告→commit"流程拆成4个角色，由监督员在3道卡点审计。

**Architecture:** 四个agent（开发含编译、测试、报告、监督）+ 一个编排命令。子代理间不共享上下文，全部通信落盘到run目录；监督员只读产物不采信声明。所有环境细节抽到`mccl-env.sh`（不入库），技术知识进`references/`（入库）。

**Tech Stack:** Markdown（agent定义 + frontmatter）、Bash（自检脚本、远程执行）、Claude Code的agents/commands/settings机制。

## Global Constraints

以下约束适用于每个任务，值从spec逐字抄录：

- **`测试.md`永不入库。** 已在`.gitignore`第2行，首次commit前就位，当前不在历史中。任何任务都不得`git add -f 测试.md`
- **已跟踪文件不得含真实内网IP、主机名映射、真实路径。** 这些只存在于`mccl-env.sh`（不入库）。`mccl-env.sh.example`用`<占位符>`
- **agent一律读`mccl-env.sh`取环境值，不硬编码**
- **本仓库只存agent定义**，无法直连远程节点。agent的远程执行行为在本仓库**无法端到端验证**，只能验证静态不变式（frontmatter合法、工具权限正确、变量引用闭合、无IP泄漏）。行为验证推迟到拷入真实仓库后
- **监督员审产物不审声明**：`change.patch`说了算不是`dev-change.md`说了算；`test-*.log`说了算不是`report.md`说了算
- **重试分层**：编译内循环≤5、测试外循环`attempt`≤3、报告内循环≤2。只有监督(dev)和监督(test)判REWORK才递增`attempt`
- **偏离spec一处**：监督checklist从`.claude/agents/checklists/`改到`references/supervisor-checklists/`。理由：现有插件的agent定义全部平铺在`agents/`下，无证据表明子目录不会被当作agent扫描，缺frontmatter的checklist可能触发加载错误。放`references/`零风险

---

## File Structure

```
.claude/
├── agents/
│   ├── mccl-developer.md      # 开发（含编译、分发）
│   ├── mccl-tester.md         # 测试（场景A + 场景B）
│   ├── mccl-reporter.md       # 报告（禁Bash）
│   └── mccl-supervisor.md     # 监督（3道卡点共用）
├── commands/
│   └── mccl-run.md            # 编排命令
└── settings.json              # 权限deny规则（硬拦截）
references/
├── mccl-domain.md             # 对称内存/内核选型等领域知识
├── mccl-build-pitfalls.md     # 编译陷阱
├── mccl-safety.md             # 硬禁令
└── supervisor-checklists/
    ├── dev.md                 # 卡点1：规范性+编译完整性
    ├── test.md                # 卡点2：覆盖度
    └── report.md              # 卡点3：准确性
tests/
└── check.sh                   # 静态不变式自检
mccl-env.sh.example            # 环境模板（占位符）
README.md                      # 安装到真实仓库的说明
```

拆分依据：agent定义按角色分文件（一个角色一份提示词，边界即职责边界）。checklist独立于supervisor agent，因为三份checklist会各自演进，而审计方法论只有一套。`references/`按知识类型分（领域/编译/安全），三者的读者不同——领域知识给开发，编译陷阱给开发，安全禁令给所有人。

## Interfaces（跨任务契约）

**环境变量**（Task 1定义，Task 4/5/8消费）：
`MCCL_NODE0_IP` `MCCL_NODE1_IP` `MCCL_NODE2_IP` `MCCL_NODE3_IP` `MCCL_HOST_SPEC` `MCCL_NP` `MCCL_CONTAINER` `MCCL_MACA_PATH` `MCCL_LOCAL_SRC` `MCCL_REMOTE_SRC` `MCCL_REMOTE_WORKDIR` `MCCL_MPIRUN` `MCCL_PERF_BIN_ASYM` `MCCL_PERF_BIN_SYM` `MCCL_LD_LIBRARY_PATH` `MCCL_TCP_IF_INCLUDE`

**run目录文件名**（Task 8创建目录，Task 4/5/6/7读写）：
`task.md` `dev-change.md` `change.patch` `build.log` `test-preflight.md` `test-asymmetric.log` `test-symmetric.log` `test-result.md` `test-anomaly.md` `report.md` `verdict-dev.md` `verdict-test.md` `verdict-report.md` `escalation.md` `timeline.md`

**verdict格式**（Task 7产出，Task 8解析）：文件首行必须是 `判决: PASS` 或 `判决: REWORK` 或 `判决: ABORT`，供编排命令用`head -1`可靠提取。

**agent名**（Task 4/5/6/7定义，Task 8调用）：`mccl-developer` `mccl-tester` `mccl-reporter` `mccl-supervisor`

---

### Task 1: 环境模板与自检脚本

**Files:**
- Create: `mccl-env.sh.example`
- Create: `tests/check.sh`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces: 上方"环境变量"契约的全部16个变量名；`tests/check.sh`（后续每个任务都会往里加不变式）

- [ ] **Step 1: 写自检脚本，先只放能立刻验证的三条不变式**

Create `tests/check.sh`:

```bash
#!/usr/bin/env bash
# MCCL数字员工工具包自检。每次commit前跑：bash tests/check.sh
# 只验证静态不变式。agent的实际行为需拷入真实仓库后验证。
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "ok:   $*"; }

# --- 1. 测试.md 从未进入 git 历史 ---
if git log --all --pretty=format: --name-only 2>/dev/null | grep -qx '测试.md'; then
  err "测试.md 出现在 git 历史中（不可逆，需 filter-branch 清理）"
else
  ok "测试.md 不在 git 历史中"
fi

# --- 2. 测试.md 当前被忽略 ---
if git check-ignore -q 测试.md 2>/dev/null; then
  ok "测试.md 被 .gitignore 拦截"
elif [ -e 测试.md ]; then
  err "测试.md 存在但未被忽略"
else
  ok "测试.md 不存在于工作区"
fi

# --- 3. 已跟踪文件不得含私网IP字面量 ---
ip_hits=$(git ls-files -z | xargs -0 grep -lE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' 2>/dev/null || true)
if [ -n "$ip_hits" ]; then
  err "已跟踪文件含私网IP：$ip_hits"
else
  ok "已跟踪文件无私网IP字面量"
fi

# --- 4. mccl-env.sh 不得被跟踪 ---
if git ls-files --error-unmatch mccl-env.sh >/dev/null 2>&1; then
  err "mccl-env.sh 被跟踪（含内网信息，应只提交 .example）"
else
  ok "mccl-env.sh 未被跟踪"
fi

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有失败项"
exit "$fail"
```

- [ ] **Step 2: 跑一遍确认通过**

Run: `bash tests/check.sh`
Expected: 4条`ok:`，末尾`全部通过`，退出码0

- [ ] **Step 3: 验证不变式3真的能抓到IP（负向测试）**

Run:
```bash
printf '10.130.40.60\n' > /tmp/ipbait.md && cp /tmp/ipbait.md ./ipbait.md && git add ipbait.md
bash tests/check.sh; echo "退出码=$?"
git rm -f --cached ipbait.md && rm -f ipbait.md ipbait.md
```
Expected: 出现`FAIL: 已跟踪文件含私网IP：ipbait.md`，退出码=1。清理后再跑`bash tests/check.sh`应恢复`全部通过`

**这一步不能跳。** 一个永远不会失败的检查等于没有检查。

- [ ] **Step 4: 写环境模板**

Create `mccl-env.sh.example`:

```bash
#!/usr/bin/env bash
# 拷贝为 mccl-env.sh 并填入真实值。mccl-env.sh 不入库（见 .gitignore）。
# 所有 agent 从此文件取环境值，不得硬编码。

# --- 四个计算节点 ---
# NODE0 是唯一的编译节点（容器宿主）。NODE1/2/3 只接受 scp 的 libmccl.so，
# 禁止在其上编译或修改源码。
export MCCL_NODE0_IP="<node0-ip>"
export MCCL_NODE1_IP="<node1-ip>"
export MCCL_NODE2_IP="<node2-ip>"
export MCCL_NODE3_IP="<node3-ip>"

# mpirun 的 -host 参数，每节点8卡；总进程数
export MCCL_HOST_SPEC="${MCCL_NODE0_IP}:8,${MCCL_NODE1_IP}:8,${MCCL_NODE2_IP}:8,${MCCL_NODE3_IP}:8"
export MCCL_NP=32

# Node 0 上的编译容器名
export MCCL_CONTAINER="<container-name>"

# --- 编译 ---
# 必须指向含正确 mcMemFabricHandle_t 定义的 MACA 安装。另一个常见路径下的定义
# 是旧版 stub，结构体尺寸不同，会导致跨节点对称内存句柄异常。
# 详见 references/mccl-build-pitfalls.md
export MCCL_MACA_PATH="<maca-path>"
export MCCL_LOCAL_SRC="<local-repo-path>"
export MCCL_REMOTE_SRC="<remote-src-path>"

# agent 在远程的可写范围边界。此目录之外一律禁止修改。
export MCCL_REMOTE_WORKDIR="<remote-workdir>"

# --- 测试 ---
export MCCL_MPIRUN="<mpirun-path>"
export MCCL_PERF_BIN_ASYM="<asymmetric-perf-binary>"  # 场景A：不带 -R
export MCCL_PERF_BIN_SYM="<symmetric-perf-binary>"    # 场景B：带 -R 2
export MCCL_LD_LIBRARY_PATH="<lib-path>:<ompi-lib-path>"
export MCCL_TCP_IF_INCLUDE="<cidr>"
```

- [ ] **Step 5: 确认模板本身不触发IP检查，然后提交**

Run:
```bash
git add mccl-env.sh.example tests/check.sh && bash tests/check.sh
```
Expected: `全部通过`（占位符是`<node0-ip>`不是IP字面量）

```bash
git commit -m "工具包骨架：环境模板与静态自检

check.sh 验证的是静态不变式，不验证 agent 行为——本仓库连不上
远程节点，行为验证推迟到拷入真实仓库后。

IP 检查已做负向测试确认能抓到 10.130.40.60。"
```

---

### Task 2: references/ 领域知识

agent缺MCCL领域知识就无法工作——不知道`extLsaRankList[r]`存的是world rank而非slot索引，第1轮就会写错代码。

**Files:**
- Create: `references/mccl-domain.md`
- Create: `references/mccl-build-pitfalls.md`
- Create: `references/mccl-safety.md`

**Interfaces:**
- Consumes: 无
- Produces: 三个文件路径，被Task 4/5/7的agent frontmatter之后的正文引用

**知识来源：`测试.md`（工作区内，未入库）。** 提炼时严格分离：技术知识入库，IP/主机映射/真实路径不入库（后者已在`mccl-env.sh`）。

- [ ] **Step 1: 写 references/mccl-domain.md**

必须覆盖以下要点（内容从`测试.md`提炼，不得臆造）：

- **对称内存8+3窗口slot语义**：`extLsaRankList`共`extLsaSize`个slot；`[0, nodeSize)`是本节点8个rank的LSA地址，`[nodeSize, extLsaSize)`是跨节点同`peerSocketId`的3个rank。`extLsaSize = nodeSize + nNodes - 1`
- **`extLsaRankList[r]`存的是world rank号，不是slot索引**——这条最容易搞错
- **拓扑常量**：OAM32 PCIe Switch为nNodes=4/nodeSize=8/GROUP=8/extLsaSize=11；OAM64为nNodes=8/nodeSize=8/GROUP=8/extLsaSize=15。由`devrOamNodeCount()`直接返回，不经hostHash动态计算
- **`info.rank % GROUP`的由来**：`CliqueManager::IsSupportMultiNode()`不匹配OAM32/64，故`useLocalTopo = false`，`info.rank`是world rank（0..nRanks-1）；但`ipc_input_buffer[]`下标是LSA slot（0..10），直接用`info.rank`索引会越界。修复是`info.rank % GROUP`（= `% nodeSize`）取`lsaSelf`
- **FC AllReduce内核选型边界**：`fc8xn_3d_mesh_oneshot`(OFC32_LL)覆盖1B~16KB，上界来自`checkKernelInfos[]`的`LIMIT_16K_1`=16385；`fc8xn_3d_mesh_allreduce_unk`(OFC32_UNK)覆盖16KB+1~16MB，上界来自`CliqueManager::IsSupported()`的OAM32分支。超16MB回退Ring/Tree。`FcByteLimit`默认8GB对OAM32不生效——OAM32分支在`IsSupported()`中提前return
- **`fc8xn_3d_mesh_allreduce_unk`未启用及其阻塞bug**：该内核按`R = 0..31`索引`in_buffer[OFC_IO_UNK(R)]`，但对称路径下`info.in_buffer`/`info.out_buffer`仍是单个rank的user buffer，按0..31索引会越界。启用前必须修
- **已知风险**：`sameSocketRanks`路径要求`sameSocketRankCount == nNodes`；若`peerSocketId`分布不对称，`extLsaRankList`尾部slot为0，后续用0作worldRank会失败。当前OAM32/64拓扑已验证无此问题
- **临时补丁史**：`021417e`(skip cross-node LSA)、`a703e97`(skip UDS cross-node)均已revert，被`37ba549`(Fabric handle + 全局bootstrapAllGather)取代。**这两个是"跳过"不是"修复"，是绕过式补丁的反面教材**

- [ ] **Step 2: 写 references/mccl-build-pitfalls.md**

必须覆盖：

- **MACA_PATH两个版本的差异**：正确版本的`mcMemFabricHandle_t`是1112字节（含scatter buffer），错误版本是80字节旧版stub。用错会导致跨节点对称内存句柄异常、UDS Connection refused。路径值见`$MCCL_MACA_PATH`
- **macaify增量编译陷阱**：改`.cc`/`.h`后必须`rm -rf build/macaify`再`make`。macaify拷贝依赖CMake的`copy_if_different`，不检测源文件时间戳，不清理会编译到旧代码——**这是最隐蔽的坑，会让人以为改动没生效**
- **何时需要全量重编**：仅CMakeLists.txt变更或编译异常时才`rm -rf build && mkdir build && cmake ...`
- **mxcc报`__clang_maca_runtime_wrapper.h`找不到**：需建符号链接，把MACA安装的`mxgpu_llvm/bin`链到`$MCCL_MACA_PATH/mxgpu_llvm/bin`
- **Kernel展开规模**：`expand_collectives()`按（操作×规约op×数据类型）展开约300+个TU，`.cu`复制到`macaify/`改名`.cu.cpp`由mxcc处理。全量编译慢，用`make -j50`
- **加快迭代的CMake选项**：`-DBUILD_ALLREDUCE_ONLY=ON`仅编译AllReduce kernel。`-DUSE_SPLIT_KERNELS=ON`推荐常开

- [ ] **Step 3: 写 references/mccl-safety.md**

硬禁令清单，每条标注违反后果（ABORT / REWORK）：

- 禁止在NODE1/2/3上编译或修改源码，这三台只接受scp的`libmccl.so` → ABORT
- 禁止修改`$MCCL_REMOTE_WORKDIR`之外的任何远程文件 → ABORT
- 禁止重启远程节点。mpirun hang超5分钟时采集`dmesg`和IB状态后上报，**不重启** → ABORT
- 禁止`git push` → ABORT
- 禁止删除系统文件 → ABORT
- 测试FAIL时**不删除远程源码**（保留供下轮增量编译）→ REWORK
- 交付的diff中不得残留调试代码。调试期间允许`printf`/`cout`/`MCCL_DEBUG`宏 → REWORK
- 绕过性改动（跳过/禁用/注释掉）必须显式声明，不得静默混入 → 标记，需人工决策

- [ ] **Step 4: 自检并提交**

Run: `git add references/ && bash tests/check.sh`
Expected: `全部通过`（三份文档不得含IP——路径和IP一律用`$MCCL_*`变量名指代）

```bash
git commit -m "references: MCCL领域知识、编译陷阱、硬禁令

从测试.md提炼。技术知识入库，IP/主机映射/真实路径留在
mccl-env.sh（不入库），文档中一律用 \$MCCL_* 变量名指代。"
```

---

### Task 3: 权限硬拦截

提示词约束靠模型自觉，`settings.json`的deny规则由harness强制执行。两者是分层防御，不是二选一。

**Files:**
- Create: `.claude/settings.json`
- Modify: `tests/check.sh`（加不变式5）

**Interfaces:**
- Consumes: 无
- Produces: `.claude/settings.json`，拷入真实仓库时需合并而非覆盖

- [ ] **Step 1: 写 settings.json**

Create `.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(git push:*)",
      "Bash(reboot:*)",
      "Bash(shutdown:*)",
      "Bash(halt:*)",
      "Bash(init:*)"
    ]
  }
}
```

- [ ] **Step 2: 在 check.sh 中加入不变式5——settings.json 合法且含关键deny**

在`tests/check.sh`的`# --- 4.`块之后、`echo`之前插入：

```bash
# --- 5. settings.json 合法且含关键 deny 规则 ---
if [ ! -f .claude/settings.json ]; then
  err ".claude/settings.json 缺失"
elif ! python3 -c 'import json,sys; json.load(open(".claude/settings.json"))' 2>/dev/null; then
  err ".claude/settings.json 不是合法JSON"
else
  missing=$(python3 - <<'PY'
import json
need = {"Bash(git push:*)", "Bash(reboot:*)", "Bash(shutdown:*)"}
have = set(json.load(open(".claude/settings.json")).get("permissions", {}).get("deny", []))
print(" ".join(sorted(need - have)))
PY
)
  if [ -n "$missing" ]; then
    err "settings.json 缺少 deny 规则：$missing"
  else
    ok "settings.json 合法且含关键 deny 规则"
  fi
fi
```

- [ ] **Step 3: 跑自检**

Run: `bash tests/check.sh`
Expected: 5条`ok:`，`全部通过`

- [ ] **Step 4: 验证不变式5能抓到缺失（负向测试）**

Run:
```bash
cp .claude/settings.json /tmp/settings.bak
printf '{"permissions":{"deny":[]}}' > .claude/settings.json
bash tests/check.sh; echo "退出码=$?"
cp /tmp/settings.bak .claude/settings.json
```
Expected: 出现`FAIL: settings.json 缺少 deny 规则`，退出码=1。恢复后`全部通过`

- [ ] **Step 5: 提交**

```bash
git add .claude/settings.json tests/check.sh && bash tests/check.sh
git commit -m "权限硬拦截：deny git push / reboot / shutdown

deny规则由harness强制，不依赖模型自觉。

已知缺口：ssh 隧道内的命令（如 ssh host \"reboot\"）无法被
模式匹配拦截，这类只能靠 agent 提示词约束 + 监督员事后审计。
分层防御，不是单点。"
```

**诚实记录这个缺口很重要**：`Bash(reboot:*)`只能拦本机`reboot`。`ssh root@node "reboot"`在harness眼里是`Bash(ssh:*)`，deny不了。所以监督员的ABORT审计不是冗余，是这层的唯一补位。

---

### Task 4: mccl-developer（开发工程师，含编译）

**Files:**
- Create: `.claude/agents/mccl-developer.md`
- Modify: `tests/check.sh`（加不变式6：frontmatter完整性 + 环境变量闭合）

**Interfaces:**
- Consumes: `mccl-env.sh`的16个变量；`references/mccl-domain.md`、`references/mccl-build-pitfalls.md`、`references/mccl-safety.md`
- Produces: agent名`mccl-developer`；run目录产物`change.patch`、`dev-change.md`、`build.log`

- [ ] **Step 1: 写 agent 定义**

Create `.claude/agents/mccl-developer.md`，frontmatter逐字如下：

```yaml
---
name: mccl-developer
description: MCCL开发工程师。改源码、同步到编译节点、容器内编译、分发libmccl.so到4节点。编译失败自行修复（内循环上限5轮），编译不通过不得交付。不commit、不push、不跑测试。
tools: Read, Edit, Write, Grep, Glob, Bash
---
```

正文必须包含以下部分，内容以spec第3.1节和`references/`为准：

1. **开工前**：`source mccl-env.sh`；读`references/mccl-safety.md`、`references/mccl-build-pitfalls.md`；任务涉及对称内存时读`references/mccl-domain.md`
2. **输入**：run目录的`task.md`（含任务描述、当前轮次`attempt`、上轮`verdict-*.md`的待修项）
3. **工作流**：改本地源码 → `rsync`到`$MCCL_REMOTE_SRC` → 容器内`rm -rf build/macaify && make -j50` → 分发`libmccl.so`到4节点
4. **编译内循环**：失败自己修，**上限5轮**。5轮不过则停止并在`dev-change.md`写明失败状态交主控（主控判ABORT）。**编译不通过不得交付**
5. **硬约束**（逐字，违反即ABORT）：
   - 只改本地仓库源码和`$MCCL_REMOTE_WORKDIR`下的内容
   - 不`git commit`、不`git push`
   - 不在NODE1/2/3上编译或改源码
   - 编译前必须`export MACA_PATH=$MCCL_MACA_PATH`
   - 改`.cc`/`.h`后必须`rm -rf build/macaify`再`make`
   - 交付前清理调试代码
   - 不跑32卡测试（那是测试工程师的活）
6. **产出`change.patch`**：`git diff > <run>/change.patch`。这是监督员的审计基准
7. **产出`dev-change.md`**，结构固定：
   - `## 根因假设` — 第2轮起必须与前轮对比说明差异；**第3轮必须提出与前两轮不同的假设**，否则监督员判ABORT
   - `## 变更清单` — 文件与函数
   - `## 改动理由` — 为什么这么改能解决根因
   - `## 影响面` — 对称路径 / 非对称路径 / 两者
   - `## 绕过性改动声明` — 本次是否含"跳过/禁用/注释掉"性质改动。**有则必须显式声明并说明理由**。历史上`021417e`、`a703e97`两个skip补丁都已被revert，绕过不是修复
   - `## 编译结果` — 内循环轮次、是否通过、新增warning、`libmccl.so`的md5
   - `## 自评风险`
8. **产出`build.log`**：完整原始编译日志，不摘要

- [ ] **Step 2: 在 check.sh 中加入不变式6——agent frontmatter 与环境变量闭合**

在不变式5之后插入：

```bash
# --- 6. agent frontmatter 完整 ---
for f in .claude/agents/*.md; do
  [ -e "$f" ] || continue
  for field in name description tools; do
    if ! awk '/^---$/{n++; next} n==1' "$f" | grep -q "^${field}:"; then
      # tools 缺失合法（= 全部工具），仅 name/description 必需
      [ "$field" = "tools" ] && continue
      err "$f 的 frontmatter 缺 $field"
    fi
  done
  fm_name=$(awk '/^---$/{n++; next} n==1' "$f" | sed -n 's/^name: *//p')
  base=$(basename "$f" .md)
  [ "$fm_name" = "$base" ] || err "$f 的 name($fm_name) 与文件名($base) 不一致"
done
ok "agent frontmatter 检查完成"

# --- 7. agent 引用的 MCCL_ 变量都在 mccl-env.sh.example 中定义 ---
undef=""
for v in $(grep -rhoE '\$\{?MCCL_[A-Z0-9_]+' .claude/ references/ 2>/dev/null \
           | sed 's/[${]//g' | sort -u); do
  grep -q "^export ${v}=" mccl-env.sh.example || undef="$undef $v"
done
if [ -n "$undef" ]; then
  err "引用了未在 mccl-env.sh.example 中定义的变量：$undef"
else
  ok "环境变量引用闭合"
fi
```

- [ ] **Step 3: 跑自检**

Run: `bash tests/check.sh`
Expected: 全部`ok:`，`全部通过`

- [ ] **Step 4: 验证不变式7能抓到未定义变量（负向测试）**

Run:
```bash
echo '$MCCL_BOGUS_VAR' >> .claude/agents/mccl-developer.md
bash tests/check.sh; echo "退出码=$?"
git checkout .claude/agents/mccl-developer.md 2>/dev/null || sed -i '$ d' .claude/agents/mccl-developer.md
```
Expected: `FAIL: 引用了未在 mccl-env.sh.example 中定义的变量： MCCL_BOGUS_VAR`，退出码=1

- [ ] **Step 5: 提交**

```bash
git add .claude/agents/mccl-developer.md tests/check.sh && bash tests/check.sh
git commit -m "agent: mccl-developer（开发含编译）

编译内循环上限5轮——廉价失败给宽松预算。dev-change.md 的
根因假设字段是诊断门的输入：第3轮必须换假设，否则监督员ABORT。

绕过性改动声明是必填项，不是可选。"
```

---

### Task 5: mccl-tester（测试工程师）

**Files:**
- Create: `.claude/agents/mccl-tester.md`

**Interfaces:**
- Consumes: `mccl-env.sh`；`libmccl.so`已由`mccl-developer`分发
- Produces: agent名`mccl-tester`；`test-preflight.md`、`test-asymmetric.log`、`test-symmetric.log`、`test-result.md`、`test-anomaly.md`（仅异常时）

- [ ] **Step 1: 写 agent 定义**

Create `.claude/agents/mccl-tester.md`，frontmatter逐字如下：

```yaml
---
name: mccl-tester
description: MCCL测试工程师。核对执行前checklist，跑场景A（非对称内存）和场景B（对称内存）两个32卡测试，产出原始日志与结果汇总。不改代码、不改库、不重新编译。
tools: Read, Write, Grep, Glob, Bash
---
```

正文必须包含：

1. **开工前**：`source mccl-env.sh`；读`references/mccl-safety.md`
2. **两个场景都必须跑，不得按改动范围裁剪**：

   | | 场景A（非对称内存） | 场景B（对称内存） |
   |---|---|---|
   | 二进制 | `$MCCL_PERF_BIN_ASYM` | `$MCCL_PERF_BIN_SYM` |
   | 末尾参数 | 无 | `-R 2` |
   | 日志 | `test-asymmetric.log` | `test-symmetric.log` |
   | 验证目标 | 传统FC clique的IPC路径（回归保护） | `mcclCommWindowRegister` → `MCCL_WIN_COLL_SYMMETRIC` → `registerSymetricBuffers`对称内存路径 |

   场景A是回归保护。对称内存改动会碰到`registerSymetricBuffers`、`updateFcKernelCommonArgs`等两条路径共用的host代码，省掉场景A等于放弃回归保护。

3. **mpirun命令**（两场景除二进制和`-R 2`外完全一致）：

```bash
$MCCL_MPIRUN --allow-run-as-root -np $MCCL_NP \
  -mca pml ^ucx -mca osc ^ucx -mca btl ^openib \
  -mca btl_tcp_if_include $MCCL_TCP_IF_INCLUDE \
  -host $MCCL_HOST_SPEC \
  -x MCCL_PCIE_BUFFER_MODE=1 -x MCCL_ENABLE_FC=1 -x MCCL_P2P_LEVEL=PXB \
  -x LD_LIBRARY_PATH=$MCCL_LD_LIBRARY_PATH \
  <二进制> -b 1k -e 1k -f 2 [-R 2]
```

4. **执行前checklist**，逐条核对并记入`test-preflight.md`，每条标注核对方式与结果：
   - [ ] IP仅限`$MCCL_NODE0_IP`/`$MCCL_NODE1_IP`/`$MCCL_NODE2_IP`/`$MCCL_NODE3_IP`
   - [ ] `libmccl.so`四节点均已更新——**独立核对md5，不采信开发的声明**
   - [ ] `-np 32`，`-host`包含且仅包含四个IP的`:8`
   - [ ] `MCCL_P2P_LEVEL`和`MCCL_PCIE_BUFFER_MODE`已配置
   - [ ] `btl_tcp_if_include`为`$MCCL_TCP_IF_INCLUDE`
   - [ ] 场景A、场景B命令均已就绪

   `libmccl.so`的分发由开发做、由测试独立核对——**这道交叉验证是故意的**。`MACA_PATH`用错版本会导致`mcMemFabricHandle_t`是80字节stub、跨节点句柄直接异常，值得两个角色分别做和查。

5. **硬约束**：
   - 不改代码、不改库、不重新编译。发现问题只能上报
   - **mpirun hang超5分钟：禁止重启。**采集`dmesg`和IB状态写入`test-anomaly.md`后上报
   - 不对远程环境做破坏性操作
   - 日志必须是原始输出，不得摘要后落盘
6. **已知故障模式**（来自`测试.md`的错误处理表）：hang>5min查`dmesg`和IB状态；SegFault查`MCCL_P2P_LEVEL`是否与固件匹配；性能回退对比Baseline排查编译器优化或环境变量变化；UDS Connection refused确认`$MCCL_MACA_PATH`的`mcMemFabricHandle_t`是1112字节版本
7. **产出`test-result.md`**：每个场景的命令、退出码、关键数据、PASS/FAIL判定

- [ ] **Step 2: 自检并提交**

Run: `git add .claude/agents/mccl-tester.md && bash tests/check.sh`
Expected: `全部通过`

```bash
git commit -m "agent: mccl-tester（场景A + 场景B）

两个场景都必须跑。场景A不是可选的回归项——对称内存改动会碰
两条路径共用的host代码（registerSymetricBuffers 等），省掉
场景A等于放弃回归保护。

libmccl.so 由开发分发、测试独立核对md5，交叉验证是故意的。"
```

---

### Task 6: mccl-reporter（报告工程师）

**Files:**
- Create: `.claude/agents/mccl-reporter.md`
- Modify: `tests/check.sh`（加不变式8：reporter必须无Bash）

**Interfaces:**
- Consumes: run目录全部产物
- Produces: agent名`mccl-reporter`；`report.md`

- [ ] **Step 1: 写 agent 定义**

Create `.claude/agents/mccl-reporter.md`，frontmatter逐字如下（**`tools`中不得出现Bash**）：

```yaml
---
name: mccl-reporter
description: MCCL测试报告工程师。读run目录的产物，写单次变更的验证报告。每个数字必须能在原始日志中找到出处，未跑的场景标注"未覆盖"不得推断。无执行能力。
tools: Read, Grep, Glob, Write
---
```

正文必须包含：

1. **为什么你没有Bash**：这是防报告造假的物理隔离，不是疏漏。你没有跑测试的能力，报告里每个数字只能从`test-*.log`里摘，摘不到就必须写"未覆盖"。不要试图绕过这个限制去补数据
2. **变更清单以`change.patch`为准，不以`dev-change.md`的自述为准**
3. **产出`report.md`**，结构固定：
   - `## 变更摘要` — 改了什么、为什么
   - `## 变更清单` — 来自`change.patch`
   - `## 编译结果` — 是否通过、新增warning、产物md5（来自`build.log`）
   - `## 测试覆盖` — 场景A、场景B各自的命令、结果、关键数据
   - `## 与基线对比`
   - `## 遗留风险` — 必须体现`dev-change.md`中自评的风险
   - `## 结论` — 可否commit
   - `## 证据索引` — 每个结论指向哪个日志文件的哪几行
4. **硬约束**：
   - 每个数字必须能在原始日志中找到出处
   - 未跑的场景标注"未覆盖"，**不得从其他场景推断**
   - 结论必须与测试结果一致。测试FAIL就不能写PASS
   - `dev-change.md`若有绕过性改动声明，报告必须原样体现，不得淡化

- [ ] **Step 2: 在 check.sh 中加入不变式8——reporter 无 Bash**

在不变式7之后插入：

```bash
# --- 8. mccl-reporter 不得拥有 Bash（防报告造假的物理隔离）---
rf=".claude/agents/mccl-reporter.md"
if [ ! -f "$rf" ]; then
  err "$rf 缺失"
elif awk '/^---$/{n++; next} n==1' "$rf" | sed -n 's/^tools: *//p' | grep -qw 'Bash'; then
  err "$rf 的 tools 含 Bash——报告工程师必须无执行能力"
else
  ok "mccl-reporter 无 Bash"
fi
```

- [ ] **Step 3: 跑自检**

Run: `bash tests/check.sh`
Expected: 全部`ok:`

- [ ] **Step 4: 验证不变式8能抓到（负向测试）**

Run:
```bash
sed -i 's/^tools: Read, Grep, Glob, Write$/tools: Read, Grep, Glob, Write, Bash/' .claude/agents/mccl-reporter.md
bash tests/check.sh; echo "退出码=$?"
sed -i 's/^tools: Read, Grep, Glob, Write, Bash$/tools: Read, Grep, Glob, Write/' .claude/agents/mccl-reporter.md
```
Expected: `FAIL: .claude/agents/mccl-reporter.md 的 tools 含 Bash`，退出码=1。恢复后`全部通过`

- [ ] **Step 5: 提交**

```bash
git add .claude/agents/mccl-reporter.md tests/check.sh && bash tests/check.sh
git commit -m "agent: mccl-reporter（禁Bash）

禁Bash是防报告造假的物理隔离：没有执行能力，报告里每个数字
只能从原始日志摘，摘不到就必须标'未覆盖'。

check.sh 加了不变式守住这条——将来有人给它加Bash会被自检拦下。"
```

---

### Task 7: mccl-supervisor + 三份checklist

**Files:**
- Create: `.claude/agents/mccl-supervisor.md`
- Create: `references/supervisor-checklists/dev.md`
- Create: `references/supervisor-checklists/test.md`
- Create: `references/supervisor-checklists/report.md`

**Interfaces:**
- Consumes: run目录产物；`stage`参数（`dev`|`test`|`report`）
- Produces: agent名`mccl-supervisor`；`verdict-dev.md`、`verdict-test.md`、`verdict-report.md`。**首行格式`判决: PASS|REWORK|ABORT`是Task 8解析的契约**

一个agent配三份checklist：审计方法论只有一套（只认证据、不认声明、判决三选一），差的只是检查项。拆成三个agent会让各自提示词里的审计原则逐渐漂移。

- [ ] **Step 1: 写 supervisor agent**

Create `.claude/agents/mccl-supervisor.md`，frontmatter逐字如下：

```yaml
---
name: mccl-supervisor
description: MCCL监督员。在dev/test/report三道卡点独立审计，判决PASS/REWORK/ABORT。只读产物不采信声明，不修改任何文件。调用时必须传入stage参数。
tools: Read, Grep, Glob, Bash
---
```

正文必须包含：

1. **审计原则**（三条，所有卡点通用）：
   - **只认证据，不认声明。**`change.patch`说了算不是`dev-change.md`说了算；`test-*.log`说了算不是`test-result.md`说了算
   - **你不修改任何东西。**你有Bash是为了跑`git diff`、`md5sum`这类只读命令。**不得用它改文件、跑测试、或修复问题**——这条靠你自觉，harness拦不住你
   - **判决三选一**，不得含糊
2. **调用契约**：主控传入`stage`（`dev`|`test`|`report`）和run目录路径。按stage读对应的`references/supervisor-checklists/<stage>.md`，逐条核对
3. **输出格式**（逐字，首行必须可被`head -1`解析）：

```
判决: PASS
阶段: dev
轮次: 2
理由: <基于哪份产物的哪段内容，引用文件名和行号>
待修项: <REWORK时必填，具体到文件和行。PASS/ABORT时写"无">
升级原因: <ABORT时必填。其他时候写"无">
标记项: <需人工决策但不阻断的事项，如绕过性改动。无则写"无">
```

写入`<run>/verdict-<stage>.md`。

4. **ABORT优先于REWORK**：发现越界行为直接ABORT，不给重试

- [ ] **Step 2: 写 checklists/dev.md（卡点1：规范性 + 编译完整性）**

内容（每条标注违反后果）：

- `change.patch`与`dev-change.md`声明是否一致（**以patch为准**）→ 不一致REWORK
- diff中是否残留调试代码（`printf`/`cout`/临时`MCCL_DEBUG`）→ REWORK
- 是否改了`$MCCL_REMOTE_WORKDIR`之外的文件 → **ABORT**
- 是否试图`git push`或`git commit` → **ABORT**
- 是否在NODE1/2/3上编译或改源码 → **ABORT**
- `build.log`中`MACA_PATH`是否为`$MCCL_MACA_PATH` → 否则REWORK
- `build.log`是否有新增warning → 有则标记
- 编译是否通过；内循环是否超5轮 → 超限**ABORT**
- 是否含绕过性改动 → **标记，不得自动PASS**。历史上`021417e`、`a703e97`都是skip式补丁且都已被revert
- **第3轮专项：根因假设是否与前两轮不同**（读`verdict-dev.md`历史与`dev-change.md`的`## 根因假设`）→ 相同或属绕过性质则**ABORT**，不给第4轮
- `libmccl.so`是否已分发到4节点 → 否则REWORK

- [ ] **Step 3: 写 checklists/test.md（卡点2：覆盖度）**

- 执行前checklist是否逐条核对并记录在`test-preflight.md` → 否则REWORK
- **场景A是否跑了**（`test-asymmetric.log`存在且非空）→ 否则REWORK
- **场景B是否跑了**（`test-symmetric.log`存在且非空）→ 否则REWORK
- 测试命令是否与`mccl-env.sh`定义一致（`-np 32`、`-host`四节点`:8`、`btl_tcp_if_include`、三个`-x`环境变量）→ 否则REWORK
- 日志是否是原始输出而非摘要 → 否则REWORK
- 有无hang/SegFault未上报 → REWORK
- 是否发生重启等禁止操作 → **ABORT**
- 是否改了代码或库 → **ABORT**

- [ ] **Step 4: 写 checklists/report.md（卡点3：准确性）**

- `report.md`每个数字能否在`test-*.log`中找到出处 → **逐个抽查，找不到出处的数字即REWORK**
- 未跑的场景是否标"未覆盖"而非从其他场景推断 → REWORK
- **结论是否与测试结果一致**。测试FAIL但报告称PASS → **ABORT**
- `dev-change.md`中自评的风险是否在`## 遗留风险`中体现 → REWORK
- `dev-change.md`的绕过性改动声明是否原样体现、未被淡化 → REWORK
- 变更清单是否来自`change.patch`而非`dev-change.md`自述 → REWORK
- 报告循环是否超2轮 → **ABORT**（同一份数据写两次还不准，说明数据本身有歧义）

- [ ] **Step 5: 自检并提交**

Run: `git add .claude/agents/mccl-supervisor.md references/supervisor-checklists/ && bash tests/check.sh`
Expected: `全部通过`

```bash
git commit -m "agent: mccl-supervisor + 三份卡点checklist

一个agent配三份checklist——审计方法论只有一套，拆三个agent会让
各自的审计原则逐渐漂移。

verdict首行'判决: X'是编排命令解析的契约，格式不能动。

诚实记录：supervisor有Bash（需要跑git diff/md5sum），'不得用它
改文件'这条harness拦不住，只能靠提示词。"
```

---

### Task 8: /mccl-run 编排命令

**Files:**
- Create: `.claude/commands/mccl-run.md`
- Modify: `tests/check.sh`（加不变式9：命令引用的文件都存在）

**Interfaces:**
- Consumes: 四个agent名；verdict首行格式契约；run目录文件名契约
- Produces: `/mccl-run <任务描述>`

- [ ] **Step 1: 写编排命令**

Create `.claude/commands/mccl-run.md`：

```yaml
---
description: 跑一轮完整的MCCL开发验证流水线：开发→监督→测试→监督→报告→监督
---
```

正文必须包含：

1. **开工前**：确认`mccl-env.sh`存在（不存在则提示从`.example`拷贝并填值后再跑）；创建run目录`.mccl-runs/$(date +%Y-%m-%d-%H%M)/`；把任务描述写入`task.md`

2. **编排循环**（逐字）：

```
attempt = 1..3:
  写 task.md（任务 + attempt + 上轮 verdict 的待修项）
  Agent(mccl-developer)  → change.patch, dev-change.md, build.log
  Agent(mccl-supervisor, stage=dev)  → verdict-dev.md
    head -1 verdict-dev.md:
      REWORK → attempt++，continue
      ABORT  → 写 escalation.md，停
  Agent(mccl-tester)     → test-preflight.md, test-*.log, test-result.md
  Agent(mccl-supervisor, stage=test) → verdict-test.md
      REWORK → attempt++，打回开发，continue
      ABORT  → 写 escalation.md，停
  report_attempt = 1..2:
    Agent(mccl-reporter)   → report.md
    Agent(mccl-supervisor, stage=report) → verdict-report.md
      PASS   → break
      REWORK → report_attempt++（不递增 attempt），continue
      ABORT  → 写 escalation.md，停
    report_attempt 超2 → 写 escalation.md，停
  全绿 → 拷 report.md 到 docs/reports/，提示人工确认后 commit
attempt 超3 → 写 escalation.md，停
```

3. **打回目标的区分**（这条必须写进命令，是省钱的关键）：编译失败、测试失败打回**开发**（问题在代码）；报告不准打回**报告**（问题在描述，测试数据是好的，重跑32卡是浪费）

4. **`attempt`计数语义**：编译内循环和报告内循环**不递增`attempt`**。`attempt`计的是"改代码→上集群验证"的完整轮次

5. **全程维护`timeline.md`**：谁在什么时候被调用、判决是什么

6. **主控不得代劳**：主控只做调度和verdict解析。不得自己改代码、自己跑测试、自己写报告——那样会绕过整个审计链

7. **最终commit由人工确认**：全绿后提示用户，不自动commit

- [ ] **Step 2: 在 check.sh 中加入不变式9——命令引用的agent与文件都存在**

在不变式8之后插入：

```bash
# --- 9. 编排命令引用的 agent 均已定义 ---
cf=".claude/commands/mccl-run.md"
if [ ! -f "$cf" ]; then
  err "$cf 缺失"
else
  for a in mccl-developer mccl-tester mccl-reporter mccl-supervisor; do
    grep -q "$a" "$cf" || err "$cf 未引用 agent: $a"
    [ -f ".claude/agents/$a.md" ] || err "agent 定义缺失: .claude/agents/$a.md"
  done
  ok "编排命令引用的 agent 均已定义"
fi

# --- 10. checklist 三份齐全 ---
for s in dev test report; do
  [ -f "references/supervisor-checklists/$s.md" ] || err "checklist 缺失: $s.md"
done
ok "supervisor checklist 齐全"
```

- [ ] **Step 3: 跑自检**

Run: `bash tests/check.sh`
Expected: 全部`ok:`，`全部通过`

- [ ] **Step 4: 提交**

```bash
git add .claude/commands/mccl-run.md tests/check.sh && bash tests/check.sh
git commit -m "command: /mccl-run 编排流水线

打回目标的区分是省钱的关键：测试失败打回开发，报告不准打回报告
——报告问题重跑32卡纯属浪费。

主控只调度和解析verdict，不得代劳任何角色的活，否则绕过审计链。"
```

---

### Task 9: README 与交付验收

**Files:**
- Create: `README.md`
- Modify: `.gitignore`（补充真实仓库需要的条目说明）

**Interfaces:**
- Consumes: 全部
- Produces: 安装说明

- [ ] **Step 1: 写 README.md**

必须覆盖：

1. **这是什么**：MCCL开发验证流水线的数字员工工具包。四角色（开发含编译/测试/报告/监督）+ 三卡点 + 分层重试
2. **安装到真实仓库**：
   ```bash
   # 在 mccl_dev_supernode 仓库根目录
   cp -r <本仓库>/.claude/agents/*.md   .claude/agents/
   cp -r <本仓库>/.claude/commands/*.md .claude/commands/
   cp -r <本仓库>/references            .
   cp <本仓库>/mccl-env.sh.example      ./mccl-env.sh
   # 编辑 mccl-env.sh 填入真实值
   # 合并 .claude/settings.json 的 deny 规则（不要直接覆盖已有配置）
   # 追加到真实仓库的 .gitignore：
   #   .mccl-runs/
   #   mccl-env.sh
   ```
3. **用法**：`/mccl-run <任务描述>`
4. **重试与卡点速查表**：编译5轮 / 测试3轮 / 报告2轮；诊断门（第3轮必须换根因假设）
5. **已知限制**（诚实列出）：
   - 本仓库连不上远程节点，agent的远程执行行为**未经端到端验证**，首次在真实仓库使用时建议人工盯一轮
   - `settings.json`的deny只能拦本机命令，`ssh host "reboot"`这类隧道内命令**拦不住**，靠agent提示词约束 + 监督员事后审计补位
   - supervisor有Bash（需跑`git diff`/`md5sum`），"只读"靠提示词约束，harness不强制
   - `tests/check.sh`只验静态不变式（frontmatter、工具权限、变量闭合、无IP泄漏），不验agent行为
6. **`测试.md`不入库**：它是私有参考资料，`references/`是从它提炼的技术知识（不含IP/主机映射/真实路径）

- [ ] **Step 2: 全量自检**

Run: `bash tests/check.sh`
Expected: 全部`ok:`，`全部通过`，退出码0

- [ ] **Step 3: 最终验收——确认 测试.md 从未入库**

Run:
```bash
echo "=== git历史中的全部文件 ==="
git log --all --pretty=format: --name-only | sort -u | grep -v '^$'
echo "=== 当前跟踪的文件 ==="
git ls-files
```
Expected: 两个列表中**都不出现`测试.md`**，也不出现`mccl-env.sh`（只有`mccl-env.sh.example`）

- [ ] **Step 4: 提交**

```bash
git add README.md && bash tests/check.sh
git commit -m "README：安装说明与已知限制

诚实列出四条限制：远程行为未经端到端验证、ssh隧道内命令拦不住、
supervisor的'只读'靠自觉、check.sh只验静态不变式。

首次在真实仓库使用建议人工盯一轮。"
```

---

## Self-Review

**1. Spec coverage** — 逐节核对：

| Spec节 | 覆盖任务 |
|---|---|
| 3.1 开发工程师 | Task 4 |
| 3.2 测试工程师（场景A/B） | Task 5 |
| 3.3 报告工程师（禁Bash） | Task 6 + check不变式8 |
| 3.4 监督员 + 三卡点 | Task 7 |
| 4 编排流程 | Task 8 |
| 5 重试策略与诊断门 | Task 4（编译5轮）、Task 7（诊断门在dev.md checklist）、Task 8（attempt≤3、报告≤2） |
| 6 产物目录 | Task 8（主控创建）+ Interfaces契约 |
| 7 环境参数化 | Task 1 |
| 8 领域知识注入 | Task 2 |
| 9 git约定 | Task 1（不变式1-4）、Task 9（README）、`.gitignore`已存在 |
| 10 不做的事 | 无任务（YAGNI边界，正确） |

无遗漏。Spec第3节提到的硬约束额外由Task 3（settings.json）加了一层强制，超出spec但不冲突——spec只说了约束内容，没规定强制手段。

**2. Placeholder scan** — 无TBD/TODO/"类似Task N"/"添加适当的错误处理"。每个负向测试都给了完整命令和预期输出。agent正文给的是"必须覆盖的要点+逐字硬约束"而非全文——这是有意的：agent定义是提示词不是代码，spec已committed可读，逐字重抄整份提示词会让计划变成实现本身。但**所有不可臆造的内容（frontmatter、verdict格式、mpirun命令、环境变量名、checklist条目）都是逐字给出的**。

**3. Type consistency** — 交叉核对：
- agent名在Task 4/5/6/7定义，Task 8的不变式9逐个校验存在性 ✓
- 环境变量名Task 1定义16个，Task 4的不变式7自动校验闭合 ✓
- verdict首行`判决: X`在Task 7产出、Task 8用`head -1`解析 ✓
- run目录文件名在Interfaces契约统一，Task 4/5/6/7/8引用一致 ✓
- checklist路径`references/supervisor-checklists/<stage>.md`在Task 7创建、Task 7的agent正文引用、Task 8的不变式10校验 ✓

**一处已修正的隐患**：check.sh的不变式编号在Task 3加了5、Task 4加了6和7、Task 6加8、Task 8加9和10——编号连续，无冲突。

## 验证能力的诚实边界

这个计划里的"测试"是静态不变式检查，不是行为测试。能验的：frontmatter合法、reporter确实没有Bash、环境变量引用闭合、无IP泄漏、`测试.md`不在历史。**不能验的**：开发agent会不会真的拒绝`git push`、监督员会不会真的判ABORT、编译内循环会不会真的停在5轮。后者需要真实仓库+远程节点，本仓库做不到——这是Global Constraints里已声明的限制，不是计划的疏漏。

每个新增的不变式都配了负向测试（故意破坏→确认FAIL→恢复）。一个永远不会失败的检查等于没有检查。
