# MCCL数字员工工具包

MCCL（MetaX Collective Communications Library）开发验证流水线的数字员工工具包：四个agent + 三道监督卡点 + 分层重试，用来在真实MCCL仓库（`mccl_dev_supernode`）里跑一轮"改代码 → 上集群验证 → 出报告"的完整闭环，并让每一步的产出都经独立监督员审计。节点数可配置（1/4/8三档，见下方"节点数配置"一节），不同档位覆盖的验证范围不同。

**本仓库只存agent定义与静态自检，不产生运行产物。** 运行产物（`.mccl-runs/`）在拷贝到真实仓库、配好`mccl-env.sh`之后才会出现。

## 这是什么

四个角色：

| Agent | 职责 | 工具 |
|---|---|---|
| `mccl-developer` | 改源码、同步编译节点、容器内编译、分发`libmccl.so`到4节点。编译失败内循环自修复（上限5轮）。不commit、不push、不跑测试。 | 含Bash |
| `mccl-tester` | 按`$MCCL_NNODES`选择模式：多节点（4/8）跑场景A（非对称内存）+ 场景B（对称内存）两个`mpirun`测试；单节点（1）跑单节点冒烟，并在报告里显式声明未覆盖的路径。产出原始日志。不改代码、不重新编译。 | 含Bash |
| `mccl-reporter` | 读run目录产物，写验证报告，每个数字必须能在原始日志里找到出处，未覆盖场景标"未覆盖"不得推断。 | **无Bash**（见下） |
| `mccl-supervisor` | 在dev/test/report三道卡点独立审计，判PASS/REWORK/ABORT。只认落盘产物，不采信自述。 | 含Bash（只读用途） |

三道监督卡点：`stage=dev`（开发之后）、`stage=test`（测试之后）、`stage=report`（报告之后），全部由`mccl-supervisor`承担，每次调用都是独立开工，互不共享上下文。

分层重试：编译内循环（`mccl-developer`内部，上限5轮，不体现在`attempt`上）/ `attempt`（改代码→上集群完整闭环，上限3轮，只有监督(dev)或监督(test)判REWORK才递增）/ 报告内循环（`report_attempt`，上限2轮，只重跑`mccl-reporter`，不重跑开发/测试）。详见下方速查表。

编排入口：`commands/mccl-run.md`（插件装法下随插件安装为`/mccl-run`），一次调用跑完整条流水线：开发→监督→测试→监督→报告→监督。

### 关于`mccl-reporter`禁Bash

这是本工具包里最重要的一处设计，值得单独说明：报告工程师的`tools`字段里没有`Bash`，这是一道**物理隔离**，不是配置疏漏。如果报告工程师同时具备执行能力，遇到数据缺失时就有可能"跑一下补个数字"——这个临时补的实验不在开发/测试两个环节的审计链条里，监督员看不到，事后也没人能复现。禁Bash让这种事在物理上不可能发生：报告工程师手里没有能执行命令的工具，遇到数字对不上原始日志，唯一能做的诚实动作就是写"未覆盖"。`tests/check.sh`的不变式8专门校验这一点。

## Windows 用户先看这里

这套工具包全是 bash（`source`、`ssh`、`rsync`、`docker exec`、`git rev-parse`）。**纯 PowerShell 跑不了**——PowerShell 不认 `source`，agent 开工第一步 `source mccl-env.sh` 就失败，后面全塌。你需要一个 bash 环境。

**Claude Code 在 Windows 上怎么选 bash：**

| | WSL 2（推荐） | Git Bash | 纯 PowerShell |
|---|---|---|---|
| 装了会自动用吗 | 在 WSL 终端里启动 claude | 装了 Git for Windows 就自动用，零配置 | — |
| `rsync`（推源码） | 开箱即有 | **默认没有，要手动装** | 无 |
| `ssh-copy-id`（配免密） | 有 | **经常缺，要手动补** | 无 |
| 本地源码路径写法 | `/mnt/d/workspace/...` | `/d/workspace/...` | 不适用 |
| 结论 | 最稳，基本直接能用 | 能用，但 rsync/ssh-copy-id 缺了得先补 | **跑不了** |

**推荐 WSL 2**：`rsync` 和 `ssh-copy-id` 是本工具包的硬依赖（前者推源码、后者配免密），Git Bash 两个都可能缺，缺一个 AI 跑到那步就直接失败。装 WSL：

```powershell
wsl --install
```

装完在 **WSL 终端里**（不是 PowerShell）装 Claude Code、启动 `claude`。之后 README 里所有命令照搬，只有 `mccl-env.sh` 里的本地源码路径要用 WSL 写法：`export MCCL_LOCAL_SRC="/mnt/d/workspace/..."`（D 盘在 WSL 里是 `/mnt/d`，Git Bash 里是 `/d`）。

### 让 AI 驱动：你只填配置 + 输一次密码

你不用自己敲那些 bash 命令，可以让 AI 替你跑（`mccl-setup-ssh`、`/mccl-run`、`check.sh` 它都能执行）。分工：

| 事情 | 谁做 |
|---|---|
| 填 `mccl-env.sh`（节点IP、路径、容器名） | **你**，一次 |
| 第一次配 SSH 密钥输密码 | **你**，一条命令，一次 |
| 配免密检查、跑测试、出报告、自检 | **AI** |

**唯一天生需要你的是第一次输 SSH 密码。** `ssh-copy-id` 要交互输密码，AI 背后没有人能输。所以当 AI 替你跑 `mccl-setup-ssh` 碰到"要配密钥"时，它不会卡死，而是把现成命令打给你：

```
配密钥要输一次密码，这一步只能你自己来。请在你的终端里手动跑这一条：
    ssh-copy-id -o StrictHostKeyChecking=accept-new root@<你的编译节点>
跑完再让AI重新执行本脚本，它就会跳过这步继续往下检查。
```

你复制这一条、输一次密码，密钥**永久有效**，以后连这步都省了。实际用起来：对 claude 说"帮我配好环境并跑一轮测试" → AI 跑到密钥步停下给你命令 → 你输一次密码 → 说"配好了" → AI 继续跑完整条流水线。除了填配置和这一次密码，你不用碰命令行。

## 快速开始

（Linux/macOS 直接照做；Windows 先读上面「Windows 用户先看这里」，在 WSL 或 Git Bash 里做以下步骤。）

从零到跑通第一轮：

```bash
# 1. 装插件（两种装法见下方「安装到真实仓库」一节，此处以插件装法为例）
/plugin marketplace add https://github.com/wongkq/mccl-digital-employee.git
/plugin install mccl-digital-employee@mccl-digital-employee

# 2. 在MCCL仓库根（mccl_dev_supernode）拷配置模板并填值
cd <你的MCCL仓库根>
cp ~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/mccl-env.sh.example ./mccl-env.sh
# 编辑mccl-env.sh：填入MCCL_NODES、MCCL_CONTAINER、MCCL_MACA_PATH等18个变量的真实值

# 3. 配好本机到编译节点的免密（<插件根> 是什么、怎么查，见紧接着的说明）
bash <插件根>/bin/mccl-setup-ssh

# 4. 在MCCL仓库根启动claude
claude

# 5. 跑第一轮
/mccl-run <任务描述>
```

**必须在MCCL仓库根目录启动claude。** 四个子代理开工第一步都是`git rev-parse --show-toplevel`锚定`REPO_ROOT`，`mccl-env.sh`、MCCL源码、`.mccl-runs/`都挂在这个根下面（`agents/mccl-developer.md`第1节、`agents/mccl-tester.md`第1节、`agents/mccl-supervisor.md`第2节口径一致）。子代理继承的是主会话启动时的工作目录，不是它自己猜的路径——虽然在仓库子目录里启动`git rev-parse --show-toplevel`也能解析出仓库根，但主控在`commands/mccl-run.md`第2节里把`RUN_DIR`拼成`$REPO_ROOT/.mccl-runs/...`并作为绝对路径传给每个子代理；如果你在别的目录启动、又手动`cd`过仓库，容易在"我以为的仓库根"和"实际解析出的仓库根"之间产生认知错位，导致你后面手动拼路径（例如下方场景化调用时）对不上。最省心的做法就是老老实实在仓库根启动。

### `<插件根>`是什么、怎么查

README里凡是写`<插件根>`的地方（如`bash <插件根>/bin/mccl-setup-ssh`），指的都是**这套工具包的文件实际落地的那个目录**——里面有`agents/`、`commands/`、`references/`、`bin/`、`tests/`、`mccl-env.sh.example`。它不是固定值，取决于你用哪种装法，所以写成占位符：

- **插件装法**：`~/.claude/plugins/marketplaces/<某目录>/plugins/mccl-digital-employee/`。`<某目录>`因add方式而不同，别硬记。
- **拷贝装法**：你`git clone`到的地方，如`~/mccl-digital-employee/plugins/mccl-digital-employee/`。

**不用猜，一条命令查出来**（找那个装着`references/`的目录）：

```bash
find ~/.claude/plugins ~ -maxdepth 8 -name mccl-safety.md 2>/dev/null | sed 's|/references/mccl-safety.md||'
```

打印出来的就是`<插件根>`。之后凡是README让你`bash <插件根>/xxx`，把`<插件根>`换成这条查出来的路径即可。例如查出来是`~/mccl-digital-employee/plugins/mccl-digital-employee`，那么配免密就是`bash ~/mccl-digital-employee/plugins/mccl-digital-employee/bin/mccl-setup-ssh`。

**注意区分两个不同的"根"**：`<插件根>`是工具包文件所在处（你手动敲那几条命令时要填它）；`REPO_ROOT`是你的MCCL仓库根（agent运行时自己`git rev-parse`解析，不用你管）。agent跑起来后靠`bin/mccl-toolkit-root`自动定位插件根，也不用你告诉它——`<插件根>`只在**你手动执行**`mccl-setup-ssh`、`check.sh`这类命令时才需要你填。

## 安装到真实仓库

两种装法都支持，装完都还需要一步：在你的MCCL仓库（`mccl_dev_supernode`）里配好`mccl-env.sh`。

### 方式一：插件安装（推荐）

在Claude Code里直接执行这两条：

```
/plugin marketplace add https://github.com/wongkq/mccl-digital-employee.git
/plugin install mccl-digital-employee@mccl-digital-employee
```

**第一条用完整HTTPS地址（`.git`结尾），别用`wongkq/mccl-digital-employee`简写。** 简写会被展开成SSH形式`git@github.com:...`，要求你这台机器配好了GitHub的SSH密钥——没配的机器会报`Permission denied (publickey)`。本仓库是公开的，HTTPS匿名可读，不碰SSH密钥，哪台机器都通。只有确认这台机器已经配好GitHub SSH密钥时，才可以用简写图省事。

第二条的格式是`插件名@marketplace名`，本仓库两者同名，所以是`mccl-digital-employee@mccl-digital-employee`。

插件装到`~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/`，agent定义、`references/`、`bin/mccl-toolkit-root`都在插件目录下，不进你的MCCL仓库。但`mccl-env.sh`和MCCL源码只能在**你自己的仓库**里，这是插件装法下必须分清的两个根——细节见下方"双根模型"一节。

装完插件后，仍需在MCCL仓库根目录执行：

```bash
cp ~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/mccl-env.sh.example ./mccl-env.sh
# 编辑 mccl-env.sh，填入真实的节点IP、路径、容器名等18个变量的真实值

# 合并（不要覆盖）你仓库已有的 .claude/settings.json：
#   把本仓库 .claude/settings.json 里 permissions.deny 的5条规则
#   （git push / reboot / shutdown / halt / init）追加进你仓库现有的 deny 列表
#   注意：check.sh 只校验其中3条（git push / reboot / shutdown），halt / init
#   漏掉了也不会报错，合并时自己对一遍

# 追加到你仓库的 .gitignore（若已有类似条目则跳过）：
#   .mccl-runs/
#   mccl-env.sh
```

### 方式二：直接拷贝到项目（老装法，仍然支持）

先把本仓库clone到本地，再从它拷进你的MCCL仓库：

```bash
# 1. clone 本工具包（放哪都行，这里以家目录为例）
git clone https://github.com/wongkq/mccl-digital-employee.git ~/mccl-digital-employee

# 2. 进你的 MCCL 仓库根，从工具包拷文件
cd <你的MCCL仓库根>
SRC=~/mccl-digital-employee/plugins/mccl-digital-employee
mkdir -p .claude/agents .claude/commands
cp $SRC/agents/*.md    .claude/agents/
cp $SRC/commands/*.md  .claude/commands/
cp -r $SRC/references  .    # 含 supervisor-checklists/ 子目录，-r 会带上
cp $SRC/mccl-env.sh.example  ./mccl-env.sh
# 编辑 mccl-env.sh，填入真实的节点IP、路径、容器名等18个变量的真实值

# 合并（不要覆盖）真实仓库已有的 .claude/settings.json：
#   把本仓库 .claude/settings.json 里 permissions.deny 的5条规则
#   （git push / reboot / shutdown / halt / init）追加进真实仓库现有的 deny 列表
#   注意：check.sh 只校验其中3条（git push / reboot / shutdown），halt / init
#   漏掉了也不会报错，合并时自己对一遍

# 追加到真实仓库的 .gitignore（若已有类似条目则跳过）：
#   .mccl-runs/
#   mccl-env.sh
```

这种装法下`references/`直接在项目里、`bin/`不在PATH，agent会自动退回`$REPO_ROOT`当`TOOLKIT_ROOT`——不需要额外配置，见下方"双根模型"。

### 双根模型

不管哪种装法，agent运行时都要分清两个根：

| 根 | 怎么取 | 下面有什么 |
|---|---|---|
| `TOOLKIT_ROOT` | `mccl-toolkit-root`命令（插件装法下`bin/`在PATH里），取不到就退回`$REPO_ROOT` | `references/`（领域知识、监督checklist） |
| `REPO_ROOT` | `git rev-parse --show-toplevel` | `mccl-env.sh`、MCCL源码、`.mccl-runs/` |

插件安装时两者是不同目录（插件在`~/.claude/plugins/...`，仓库是你自己的MCCL仓库）；项目内拷贝装法下两者是同一目录，`mccl-toolkit-root`取不到时的退回逻辑保证了这种情况照样能用。

装完之后建议跑一次自检（`<插件根>`怎么查见上方「`<插件根>`是什么、怎么查」）：

```bash
bash <插件根>/tests/check.sh
```

这份`tests/check.sh`本身也可以整份拷进真实仓库长期留用，作为每次改动agent定义/references后的静态自检。

## 更新插件

仓库有新提交后，插件装法（方式一）的用户按三步拿到更新：

```
# 1. 刷新 marketplace 索引（重新拉远程仓库最新内容）
/plugin marketplace update mccl-digital-employee

# 2. 把插件升到最新
/plugin update mccl-digital-employee@mccl-digital-employee

# 3. 激活新版本（不用重启claude，这条即可）
/reload-plugins
```

**本插件不设固定版本号，跟着 commit 走**——`plugin.json` 里刻意不写 `version` 字段，所以每推一个新 commit，用户 update 就能拿到，不用等"发版"。（如果哪天改成写死 `version`，就必须每次改动都手动 bump 那个号，否则用户 update 会显示"已是最新版"、拿不到新内容——这个坑本插件用不设版本号来规避。）

**嫌手动麻烦可以开自动更新**：`/plugin` 打开管理器 → **Marketplaces** 标签 → 选中本 marketplace → 启用 **auto-update**。之后 claude 每次启动会在后台检查更新，有新版会提示你 `/reload-plugins`。

**拷贝装法（方式二）的更新**就是普通 git：进你 clone 工具包的目录 `git pull`，再重新 `cp` 一遍到 MCCL 仓库（`agents/`、`commands/`、`references/`）。`mccl-env.sh` 是你自己填的、不会被覆盖，放心。

**看当前装的是哪个版本 / 有没有加载错误**：`/plugin` → **Installed** 标签，或 `claude plugin list`。

## 换机器 / 换节点IP

IP变了只改一个文件：`mccl-env.sh`（不入库）。改完跑一次：

```bash
bash <插件>/bin/mccl-setup-ssh
```

**只需配"本机 → 编译节点（Node 0）"一条链路。**工具包的规则是一律经`$MCCL_NODE0_IP`跳转
（见`references/mccl-remote-ops.md`第5节），编译节点 → 其余节点是节点之间的免密，
跨节点mpirun本来就依赖它、早已配好，本机配不了也不需要配。脚本会自动检查这几条链路
和容器可达性，不通会告诉你不通在哪一段。

密码只在`ssh-copy-id`时交互输入一次，**不存盘、不进环境变量、不进日志**。

> `bin/mccl-setup-ssh`目前硬编码检查"编译节点 → 3个其余节点"（对应4节点/OAM32配置），
> 是本次节点数可配置化改造未覆盖的部分——见下方"节点数配置"一节末尾的说明。
> 单节点或8节点配置下，这个自检脚本的检查条数与`$MCCL_NODES`实际的节点数对不上，
> 需要人工判断脚本报的"不通"是不是真的问题，而不能完全依赖它的退出码。

### 为什么不把密码写进配置文件

这套agent产出的日志是"完整原始输出，不摘要、不裁剪"（监督员要靠它审计）。
一旦命令行里出现`sshpass -p '密码'`，密码就会进`build.log`/`test-*.log`；
监督员grep这些日志、报告工程师读它们、报告可能被归档到`docs/reports/`——
而那个目录是入库的。密码就这样从配置文件走进了git记录。`ps aux`也会暴露它。

换机器的成本本来就只有一条`ssh-copy-id`，为省这一条命令去新增一条泄漏路径，不划算。

## 节点数配置

改节点数只改`mccl-env.sh`一行：

```bash
export MCCL_NODES="<node0-ip> <node1-ip> ..."   # 空格分隔，第一个必须是编译节点
export MCCL_GPUS_PER_NODE=8
```

`MCCL_NODE0_IP`、`MCCL_NNODES`、`MCCL_NP`、`MCCL_HOST_SPEC`都从这两行派生，不需要、也不应该手改（`tests/check.sh`不变式12会检查这几个派生量确实引用了`$MCCL_NODES`，防止手改成写死的值导致两处不一致）。

**只支持三档节点数**，因为MCCL的拓扑常量（`nNodes`/`nodeSize`/`extLsaSize`）由`devrOamNodeCount()`硬编码返回，只认OAM32（4节点）和OAM64（8节点）两种形态。但这两种形态还有一个隐含前提：`nodeSize=8`同样是硬编码值，由PCIe Switch硬件结构决定，代码里没有按`$MCCL_GPUS_PER_NODE`重新计算。所以拓扑校验同时看节点数和每节点卡数，**能测对称内存的组合只有(8卡,4节点)和(8卡,8节点)**：

| `$MCCL_NODES`个数 | `$MCCL_GPUS_PER_NODE` | 拓扑 | 测什么 | 不测什么 |
|---|---|---|---|---|
| 1 | 任意 | 单节点冒烟 | 容器内8卡本地路径：编译产物能否跑通、本节点内的kernel选型与内存注册基本行为 | **跨节点对称内存路径完全不覆盖**——`symMemoryMapLsaTeamExtended`的跨节点fabric handle导入、`bootstrapAllGather`全局交换、`37ba549`正式方案都不会执行（单节点时`extLsaSize=8+1-1=8`，跨节点slot [8,extLsaSize)根本不存在）。更关键的是`info.rank % GROUP`这类修复在单节点下**不可区分**：`info.rank`只有0..7，`GROUP=8`，`rank % 8 == rank`，有bug的代码和修好的代码行为完全一致——单节点测试对这一类越界/索引bug没有诊断能力。若`$MCCL_GPUS_PER_NODE!=8`，还要额外声明节点内对称内存路径本身也未覆盖（见下） |
| 4 | **8** | OAM32 | 场景A（非对称内存，`$MCCL_PERF_BIN_ASYM`）+ 场景B（对称内存，`$MCCL_PERF_BIN_SYM -R 2`）两个32卡`mpirun`测试，`extLsaSize=11` | 无（这是本工具包原本针对的完整拓扑） |
| 8 | **8** | OAM64 | 同OAM32，`-np 64`，`extLsaSize=15` | 无 |
| 4 或 8 | `!=8`（如"4节点2卡"） | **不支持** | 不跑 | 全部——节点数达标但每节点卡数不是8，代码里硬编码的`nodeSize=8`/`GROUP=8`与实际拓扑对不上，对称内存路径同样不会按设计启用，与下面"其他节点数"档是同一条fallback逻辑，归入同一档处理 |
| 其他节点数（2/3/5/6/7/9+...） | 任意 | **不支持** | 不跑 | 全部——`CliqueManager::IsSupported()`的OAM32分支不匹配这些节点数，对称内存路径不会启用，会静默fallback到Ring/Tree。在这种拓扑下继续跑比不跑更有害：会产生一份看起来"跑通了、有perf数据"的报告，但报告里的数字压根没测到对称内存路径。开发/测试子代理开工时会先做拓扑合法性校验，遇到这两档**停止并上报，不跑任何mpirun**（见`references/supervisor-checklists/{dev,test}.md`各自的"拓扑合法性"一条，闷头跑了判ABORT） |

单节点模式下，`test-result.md`**必须显式声明**上表"不测什么"那一格的两点（跨节点对称内存路径未执行、`info.rank % GROUP`类bug无诊断能力）；若`$MCCL_GPUS_PER_NODE!=8`，还要额外强制声明第三条（每节点非8卡、`nodeSize=8`硬编码不匹配、节点内对称内存路径未覆盖）——这是监督员`stage=test`卡点专门核对的一条，漏了判REWORK，比测试没跑更严重（见`references/supervisor-checklists/test.md`第2、3条）。工具包的核心价值是"如实声明覆盖了什么"，节点数越少或每节点卡数越偏离8，这条声明就越重要。

**本次节点数可配置化改造未覆盖的部分**：`bin/mccl-setup-ssh`（免密自检脚本）仍然硬编码检查"编译节点 → 3个其余节点"这一固定形态，只对4节点配置准确；`tests/check.sh`只验证`mccl-env.sh.example`的静态派生关系，不验证agent在真实单节点/8节点集群上的实际行为（这一点与已知限制第1条一致，本身就是本仓库的固有边界，不是本次改造新引入的）。

## 编译模式：容器 vs 无容器

改编译模式只改`mccl-env.sh`一行：

```bash
export MCCL_CONTAINER="<container-name>"   # 填容器名=容器模式；留空（""）=无容器模式
```

| `MCCL_CONTAINER` | 模式 | 编译在哪跑 | 前提 |
|---|---|---|---|
| 非空（如`"zb"`） | 容器模式（现状） | 编译节点（`$MCCL_NODE0_IP`）上的容器内，远程命令套`docker exec $MCCL_CONTAINER bash -c` | 容器已建好、镜像里已装好MACA SDK与工具链 |
| 空字符串`""` | 无容器模式 | 编译节点宿主机，远程命令用`bash -lc`（登录shell，不套`docker exec`） | 宿主机上装好完整MACA SDK，且工具链（mxcc、cu-bridge）能被登录shell的`~/.bashrc`等加载到`PATH`——这是硬前提，无容器模式下没有容器替你准备环境 |

判断方式agent一律用`[ -n "$MCCL_CONTAINER" ]`，为真即容器模式。两种模式在功能上等价：拓扑校验、编译陷阱（macaify增量缓存、`MACA_PATH`选型）、md5契约（`$MCCL_NNODES + 1`份全部一致）都不因模式而变，唯一差别是远程命令是否多套一层`docker exec`。无容器模式下分发链路更简单——没有容器内外之分，编译产物直接在宿主机文件系统里，原本容器模式"两个`docker exec cp`动作"合并成一条普通`cp`（详见`references/mccl-remote-ops.md`第0.1、1、3节，`references/mccl-build-pitfalls.md`第2、3节）。

## 用法

```
/mccl-run <任务描述>
```

例如：

```
/mccl-run 修复对称内存路径下info.rank越界访问ipc_input_buffer的问题
```

主控会检查`mccl-env.sh`是否存在（不存在则停止并提示），然后创建`.mccl-runs/<YYYY-MM-DD-HHMM>/`，依次调度`mccl-developer`→`mccl-supervisor(stage=dev)`→`mccl-tester`→`mccl-supervisor(stage=test)`→`mccl-reporter`→`mccl-supervisor(stage=report)`，直到全绿产出`final-report.md`，或触发升级写出`escalation.md`（`commands/mccl-run.md`第9节）。**全绿之后不自动commit、不自动push、不自动归档到`docs/reports/`**——是否commit、commit信息怎么写，一律由人工确认后自己执行。

### 只跑测试

库已编好、已分发好，只想复测：调`mccl-tester`。**提示词里必须给绝对路径的run目录**——子代理继承的是主会话CWD，给相对路径它会写到别的地方去（`agents/mccl-tester.md`第1节"不要假设你的当前目录就是仓库根"）。示例提示词：

```
用mccl-tester子代理跑一次测试。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030/attempt-1
读该目录下change.patch、dev-change.md、build.log（开发已产出）。
产出写到同一目录：test-preflight.md、test-asymmetric.log、test-symmetric.log、
test-result.md（单节点模式对应改为test-singlenode.log）。
```

会做：按`$MCCL_NNODES`选场景，独立核对`libmccl.so`各节点md5（不采信开发自报值），跑对应`mpirun`，产出原始日志与`test-result.md`。不会做：改代码、改库、重新编译——`agents/mccl-tester.md`第5节硬约束第一条。这条路径不经过`mccl-supervisor`，判定是否合格要你自己看`test-result.md`或手动再调一次监督员。

### 只审计

不重新跑开发/测试，只审计：调`mccl-supervisor`。**必须传`stage`**（`dev`/`test`/`report`三选一），它靠这个决定读哪份checklist（`agents/mccl-supervisor.md`第2节）。示例：

```
用mccl-supervisor子代理做一次审计，stage=test。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030
（本轮产物在其下attempt-1/子目录）
```

会做：读对应checklist逐条核对落盘产物，写`verdict-<stage>.md`（report卡点是`verdict-report-<N>.md`），判决三选一（PASS/REWORK/ABORT），"理由"字段具体到文件行号。不会做：改任何文件——`agents/mccl-supervisor.md`第1节第2条，虽然它的`tools`里有Bash，但只准跑`git diff`/`md5sum`一类只读命令，这条约束由提示词自觉遵守，harness不强制拦它写文件或跑测试。

### 只写报告

调`mccl-reporter`，给run目录绝对路径。示例：

```
用mccl-reporter子代理写报告。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030/attempt-1
文件名：report-1.md（若是重写，改成report-2.md，不得覆盖report-1.md）
读该目录下change.patch、dev-change.md、build.log、test-preflight.md、
test-asymmetric.log、test-symmetric.log、test-result.md（如有test-anomaly.md一并读）。
```

会做：核对产物、摘录、汇总成八段式`report-<N>.md`，每个数字标出处（文件名+行号）。不会做：执行任何命令去补数据——它的`tools`里没有Bash（`agents/mccl-reporter.md`第1节），遇到日志里找不到的数字，唯一能做的是写"未覆盖"。

### run目录布局

```
.mccl-runs/<YYYY-MM-DD-HHMM>/
├── task.md                        # 每轮重写：任务描述 + attempt + 上轮待修项
├── timeline.md                    # 全程流水账，追加写，不分轮次
├── attempt-1/
│   ├── change.patch  dev-change.md  build.log
│   ├── verdict-dev.md
│   ├── test-preflight.md  test-asymmetric.log  test-symmetric.log  test-result.md
│   ├── test-anomaly.md            # 仅异常时出现
│   ├── verdict-test.md
│   └── report-1.md  verdict-report-1.md  [report-2.md  verdict-report-2.md]
├── attempt-2/ …                   # 同构，仅attempt递增时出现
├── escalation.md                  # 仅ABORT或超限时出现
└── final-report.md                # 全绿时，从通过的那份report-N.md拷贝而来
```

按轮次分子目录，不用平铺布局：诊断门要求`attempt`第3轮的根因假设与前两轮不同，`mccl-supervisor`需要跨轮读`attempt-1/dev-change.md`和`attempt-2/dev-change.md`比对；报告内循环的`report-N.md`同理需要保留历史。平铺到同一目录会导致第2轮覆盖第1轮，这两项设计都会失效。

## 怎么读产物

- **`timeline.md`**——最先看这个。全程流水账，追加写、不分轮次，谁在什么时候被调用、判决是什么，一眼看完不用逐个进`attempt-N/`翻（`commands/mccl-run.md`第8节）。
- **`verdict-*.md`**——首行`判决: PASS|REWORK|ABORT`（`agents/mccl-supervisor.md`第3节，这是主控`head -1`解析的硬契约）；"理由"字段必须具体到文件行号；"标记项"是需要你人工决策但不阻断流水线的事，比如绕过性改动声明——PASS也可能带标记项，别只看判决字段就划过。
- **`final-report.md`**——只在全绿时出现，是主控从通过的那份`report-N.md`原样拷贝而来（`commands/mccl-run.md`第3节第113行）。
- **`escalation.md`**——只在ABORT或超限（`attempt`超3、`report_attempt`超2）时出现，看"升级原因"字段，格式见`commands/mccl-run.md`第6节。
- **`test-preflight.md`**——测试没跑起来时先看这个。多节点模式六条、单节点模式四条（`agents/mccl-tester.md`第4a、4b节），哪条没过、怎么核对的都写在里面。
- **`attempt-N/`**——按轮次分子目录查看，产出结构见上方"run目录布局"；第2轮不覆盖第1轮，这是诊断门要求跨轮读`attempt-1/dev-change.md`、`attempt-2/dev-change.md`比对根因假设的前提，平铺到同一目录会让这项设计失效。

## 重试与卡点速查表

| 循环 | 计数变量 | 上限 | 谁递增 | 递增后落到哪 |
|---|---|---|---|---|
| 编译内循环 | 不单独计数 | 5轮 | `mccl-developer`内部，不体现在`attempt`上 | 只保留最终态的一份`change.patch`/`dev-change.md`/`build.log`；每轮的报错摘要逐轮记在`dev-change.md`的"编译结果"字段——`build.log`只有最终一次`make`的输出，佐证不了轮次，监督员数的是那份逐轮记录 |
| 改代码→上集群完整闭环 | `attempt` | 3轮 | 只有`mccl-supervisor(stage=dev)`或`stage=test`判**REWORK**时 | 新的`attempt-N/`子目录 |
| 报告内循环 | `report_attempt` | 2轮 | `mccl-supervisor(stage=report)`判**REWORK**时（不递增`attempt`） | 同一`attempt-N/`目录下新的`report-M.md` |

诊断门：`attempt`到第3轮仍未通过dev/test关口，视为连续失败，主控直接写`escalation.md`停止，不再开`attempt-4/`。第3轮开发前，监督员在`stage=dev`审计时要求本轮给出的根因假设与前两轮不同（同一假设改第三遍还不对，说明诊断方向本身错了，不该再机械重试）——这条约束写在`references/supervisor-checklists/dev.md`里，由监督员在审计时核对，不是主控自动强制。

打回目标区分（省钱的关键）：
- `stage=dev`判REWORK → 问题在代码 → 打回开发。
- `stage=test`判REWORK → 问题还是在代码（没解决问题或引入新问题）→ 同样打回开发，重新走`attempt`。
- `stage=report`判REWORK → 问题在报告怎么写，测试数据本身是好的 → 只打回报告，只重跑`mccl-reporter`，绝不重新占用集群跑一遍测试。

## 出问题怎么查

| 现象 | 原因 | 怎么办 |
|---|---|---|
| agent卡住不动、ssh没反应 | 密钥没配好，裸ssh弹密码提示，而agent背后没有人输密码 | 跑`bash <插件>/bin/mccl-setup-ssh`。所有ssh已带`$MCCL_SSH_OPTS`（`BatchMode=yes`）会立刻失败而不是挂起（`references/mccl-remote-ops.md`§0.5），若仍挂起说明有裸ssh漏网，跑`bash <插件>/tests/check.sh`第13条排查 |
| preflight md5不一致，测试不跑（多节点模式第2条） | **最常见**。编译节点`$MCCL_MACA_LIB_DIR/libmccl.so`没更新 | 这是`测试.md`原始工作流的洞：它记载的分发只有三条scp（发给非编译节点）加编译节点容器内到`/opt/maca/lib`的cp，编译节点的`$MCCL_MACA_LIB_DIR`从没写过，且全程只有`make -j50`没有`make install`。补`references/mccl-remote-ops.md`第3节"动作②"那条命令：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'cp $MCCL_REMOTE_SRC/build/libmccl.so $MCCL_MACA_LIB_DIR/'"` |
| agent说"找不到references/" | `TOOLKIT_ROOT`没解析对 | 插件装法应由`bin/mccl-toolkit-root`解析（优先`$CLAUDE_PLUGIN_ROOT`，兜底`$BASH_SOURCE`反推）；拷贝装法退回`$REPO_ROOT`。确认`references/`确实在插件根或仓库根下（`bin/mccl-toolkit-root`） |
| 主控直接停，提示`mccl-env.sh`不存在 | 没从`.example`拷贝 | `cp <插件>/mccl-env.sh.example ./mccl-env.sh`并填值（`commands/mccl-run.md`第2节第1点） |
| agent拒绝执行，说拓扑不受支持 | `MCCL_NNODES`不是1/4/8，**或**每节点卡数`MCCL_GPUS_PER_NODE`不是8而节点数是4/8（如"4节点2卡"） | 能测对称内存的组合只有 (8卡,4节点) 和 (8卡,8节点)——`nodeSize=8`是PCIe Switch硬件决定、代码硬编码的。偏离这个的多节点配置，`CliqueManager::IsSupported()`不匹配，对称内存不启用、静默fallback到Ring/Tree，**测出来的不是你以为在测的东西**，拒绝比跑更安全。单节点非8卡（如单节点2卡）是例外：能跑基础AllReduce冒烟，agent会在报告里声明未覆盖对称内存（`agents/mccl-developer.md`第6步、`agents/mccl-tester.md`第2节） |
| 报告里写"缺失"，日志明明跑了 | 日志落在远端了 | `ssh`的重定向必须在引号**外面**：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "<命令>" > "$RUN_DIR/build.log" 2>&1`，写成`ssh ... "<命令> > build.log 2>&1"`日志就留在远端（`references/mccl-remote-ops.md`§0.6）。`mccl-reporter`没有Bash、取不了远程文件，日志不在本地对它等同不存在 |
| mpirun hang超5分钟 | 见`test-anomaly.md` | **禁止重启**（`references/mccl-safety.md`第3条）。agent会采`dmesg`+IB状态后停下等你（`agents/mccl-tester.md`第5节）。你也别手动重启——这条是`测试.md`原始规程里的硬禁令 |
| 监督员判REWORK："历史产物缺失" | 前几轮的`attempt-N/`不在 | 诊断门要跨轮读`attempt-1/dev-change.md`和`attempt-2/dev-change.md`比对根因假设（`references/supervisor-checklists/dev.md`第10条）。run目录必须按轮次分子目录，不能平铺 |
| SegFault | 已知故障模式 | 查`MCCL_P2P_LEVEL`是否与固件匹配（`agents/mccl-tester.md`第6节） |
| UDS Connection refused | 已知故障模式 | 确认`$MCCL_MACA_PATH`的`mcMemFabricHandle_t`是1112字节版本，不是80字节旧版stub（`agents/mccl-tester.md`第6节、`mccl-env.sh.example`第41-43行） |

## 各角色边界速查

| 角色 | Bash | 能连测试机 | 能做什么 | 不能做什么 |
|---|---|---|---|---|
| `mccl-developer` | 有 | 能（ssh到编译节点、容器内编译） | 改源码、rsync同步、容器内编译（内循环上限5轮自修复）、按`$MCCL_NNODES`分发`libmccl.so` | 不commit、不push、不跑跨节点/多卡测试（`agents/mccl-developer.md`第5节） |
| `mccl-tester` | 有 | 能（ssh到全部节点、跑mpirun） | 按`$MCCL_NNODES`选场景跑测试、独立核对md5、产出原始日志 | 不改代码、不改库、不重新编译（`agents/mccl-tester.md`第5节） |
| `mccl-reporter` | **无** | **不能** | 读run目录已落盘产物，写报告，每个数字标出处，未覆盖场景标"未覆盖" | 不能执行任何命令去补数据——`tools`里没有Bash，这是防报告造假的**物理隔离**，不是疏漏（`agents/mccl-reporter.md`第1节、`tests/check.sh`不变式8） |
| `mccl-supervisor` | 有 | 有条件能（经跳板做只读`md5sum`/`ls`核实） | 在dev/test/report三道卡点独立审计，判PASS/REWORK/ABORT | 不修改任何文件、不跑测试、不重新编译——Bash只准只读用途（`git diff`/`md5sum`）。**这条"只读"靠提示词自觉，harness不强制**：它的`tools`里确实有Bash，技术上完全能用来写文件或跑命令，没有机制阻止（`agents/mccl-supervisor.md`第1节第2条） |
| 主控（`/mccl-run`） | 有限（仅`mkdir`/`date`/`head -1`/写自己的`task.md`等） | 不直接连 | 调度四个子代理、`head -1`解析verdict、维护`timeline.md`、判断打回目标 | 不代劳任何角色的活（不改代码、不编译、不跑mpirun、不写`dev-change.md`/`test-result.md`/`report-N.md`），也不自己下judgment——PASS/REWORK/ABORT的判断权只属于`mccl-supervisor`（`commands/mccl-run.md`第0节） |

## 目录结构

本仓库是marketplace布局，插件本体在`plugins/mccl-digital-employee/`下：

```
.claude-plugin/marketplace.json      marketplace索引
.claude/settings.json                权限deny规则模板（git push / reboot / shutdown / halt / init），
                                      插件带不走，留给用户合并进自己仓库
plugins/mccl-digital-employee/
├── .claude-plugin/plugin.json       插件清单
├── bin/mccl-toolkit-root            输出TOOLKIT_ROOT（references/所在处），两种装法都能用
├── agents/            mccl-developer.md / mccl-tester.md / mccl-reporter.md / mccl-supervisor.md
├── commands/          mccl-run.md（编排入口）
├── references/
│   ├── mccl-domain.md               领域知识（对称内存、FC kernel等）
│   ├── mccl-build-pitfalls.md       编译陷阱（含macaify增量编译坑）
│   ├── mccl-safety.md                硬禁令（8条，违反则ABORT或REWORK）
│   ├── mccl-remote-ops.md            远程调用模式手册（ssh跳板、docker exec引号嵌套、按$MCCL_NODES循环的分发差异）
│   └── supervisor-checklists/
│       ├── dev.md      test.md      report.md      三道卡点各自的监督checklist
├── mccl-env.sh.example    18个MCCL_*环境变量模板
└── tests/check.sh          13条静态不变式自检（仓库级+插件级）
docs/superpowers/{specs,plans}/      设计与实施计划
```

## 已知限制（诚实列出，不淡化）

1. **本仓库连不上远程节点，agent的远程执行行为从未端到端验证过。** `tests/check.sh`只验静态不变式（frontmatter是否合法、`mccl-reporter`确实没有Bash、环境变量引用是否闭合、已跟踪文件无私网IP字面量、`测试.md`不在git历史中、有没有裸ssh漏网），**不验agent行为**——开发agent会不会真的拒绝`git push`、监督员会不会真的判ABORT、编译内循环会不会真的停在5轮，这些都没有被验证过，因为验证它们需要真实的远程节点和真实的32卡集群，本仓库不具备。**首次在真实仓库使用，建议人工盯完整一轮**，逐步核对每个子代理落盘的产物和每次verdict，而不是直接放手跑。

2. **`.claude/settings.json`的deny规则只能拦截本机命令，拦不住隧道内命令。** deny列表按命令前缀模式匹配，例如`Bash(reboot:*)`能拦住本机直接执行`reboot`。但`ssh host "reboot"`在harness眼里匹配的是`Bash(ssh:*)`这个前缀，不是`reboot`本身，deny规则识别不到隧道内实际执行的命令，拦不住。这类风险目前只能靠两层软约束补位：agent提示词里的硬禁令（`references/mccl-safety.md`）+ 监督员事后审计核对产物。这是分层防御，不是单点防护，任何一层单独看都不完备。

3. **`mccl-supervisor`拥有Bash，"只读"这条约束纯粹靠提示词自觉，harness不强制。** 监督员需要跑`git diff`/`md5sum`等命令做只读核对，所以它的`tools`字段里必须有Bash。但harness不会区分"只读用途的Bash调用"和"写入/执行用途的Bash调用"——监督员的`tools`里确实有Bash，技术上它完全能用来改文件、跑测试、重新编译，没有任何机制阻止它这么做。这条边界能不能守住，完全取决于监督员自己是否遵守提示词里"你不修改任何东西"的约束，而不是任何技术强制。

4. **`references/`里的领域知识来自`测试.md`的提炼，可能有偏差，且反映的是某一时间点的环境状态。** `测试.md`本身是私有材料（不入库，见下），记录的编译路径选型、拓扑常量、内核选型边界等信息对应的是提炼那一刻的真实环境。如果真实仓库所在的硬件拓扑、MACA版本、内核路径发生变化，`references/`里对应的内容需要人工同步更新，工具包本身不会自动感知环境漂移。

5. **`$CLAUDE_PLUGIN_ROOT`在agent提示词正文里是否会被展开，官方文档未说明、本工具包未实测。** 这不是"验证过它不work"，而是一个未知数——我们没有找到官方文档明确保证agent的Markdown提示词正文（而非仅limited于hook/MCP配置等场景）里出现的`$CLAUDE_PLUGIN_ROOT`会被harness展开成实际路径。为了不把整套双根模型建在一个不确定的行为上，`bin/mccl-toolkit-root`把`$CLAUDE_PLUGIN_ROOT`当成"如果有就优先用"的加分项，但不依赖它——真正兜底的是用`$BASH_SOURCE`反推`../`，这条路径在两种装法下都能从脚本自身的实际位置推出正确答案，不依赖任何环境变量是否被展开。这是绕开了一处不确定性，不是确认了它一定不work或一定work。

6. **单节点/8节点拓扑下，agent的实际行为同样从未端到端验证过（与第1条同一根因）。** 节点数可配置化改造改的是agent提示词里的判断逻辑（按`$MCCL_NNODES`选分支）和`mccl-env.sh.example`的静态派生关系，`tests/check.sh`能验证的也仅限于派生量本身算对了（不变式12）——单节点模式下开发/测试agent会不会真的只做1份而非N+1份md5核对、拓扑不支持时会不会真的停止而不是"顺手跑一下"、覆盖度声明会不会真的写进`test-result.md`，这些都需要真实单节点或8节点集群才能验证，本仓库同样不具备。`bin/mccl-setup-ssh`目前也只对4节点配置的免密链路做了针对性检查，未随本次改造同步扩展（见上方"节点数配置"一节末尾）。

7. **单节点模式在设计上就测不到跨节点对称内存，这不是验证缺口，是能力缺口。** `info.rank % GROUP`这类bug在单节点下**有bug的代码和修好的代码行为完全一致**：单节点时`info.rank`只有0..7、`GROUP=8`，`rank % 8 == rank`，跨节点的8+3 slot、fabric handle、`37ba549`那一行代码全都不会执行（详见上方"节点数配置"一节、`agents/mccl-tester.md`第2a节）。工具包会强制在`test-result.md`里声明这两点未覆盖（`references/supervisor-checklists/test.md`第3条，漏了判REWORK），但你要清楚这个声明的含义：单节点跑通不代表跨节点对称内存路径没问题。

## `测试.md`不入库

`测试.md`是私有参考资料（真实环境的调试记录、内网IP、主机映射等），永远不进入本仓库的git历史，已在`.gitignore`中拦截。`references/`下的四份领域知识文档是从`测试.md`提炼出的技术知识（编译陷阱、硬禁令、远程调用模式、对称内存等领域概念），环境相关的具体值统一收敛到`mccl-env.sh`（不入库，只提交`mccl-env.sh.example`模板）。

**这条边界只有一部分是自动校验的，其余靠人工把关**——说清楚哪部分是哪部分，比笼统说"已校验"有用：

| | 谁来把关 |
|---|---|
| 内网IP字面量 | `tests/check.sh`不变式3自动校验（已跟踪文件grep私网IP段） |
| `测试.md`本身不入库 | 不变式1（不在git历史）、不变式2（被`.gitignore`拦截）自动校验 |
| `mccl-env.sh`不入库 | 不变式4自动校验 |
| 主机名/末位八位组映射（如`Host3=<末位八位组>`） | **无自动校验**，靠review。写进已跟踪文件，`check.sh`照样全绿 |
| 真实文件系统路径 | **无自动校验**，且`references/`里**确实含**真实路径 |

关于最后一行：`references/`里出现`/opt/maca`这类厂商标准安装路径是**有意保留**的说明性上下文——不写清楚"`/opt/maca`是什么、为什么不能拿它编译"，`mccl-build-pitfalls.md`第1条就讲不成。规则是`mccl-remote-ops.md:5`和`mccl-build-pitfalls.md:5`各自声明的那条：**agent实际要执行的路径一律走`$MCCL_*`变量，字面路径只能出现在解释性文字里**。这比"不含真实文件系统路径"要宽，以这两份文档自己的声明为准。
