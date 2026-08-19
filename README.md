# MCCL数字员工工具包

> ⚠️ **2026-08 精简：已移除 `mccl-developer` 与 `mccl-supervisor` 两个子代理。**
> 依赖它们的完整开发验证流水线命令 `/mccl-run`、`/mccl-bench`、`/mccl-impact-run` 已标注废弃（编排会断，文件保留备恢复）。
> 当前可用核心：`/mccl-test`（测试+报告一条龙）+ `/mccl-gpu-info`（GPU 探测）+ `/mccl-skill-sync`（经验同步）+ `/mccl-bench-queue`。
> 下方标注【已废弃】的命令仅留索引指向对应 `commands/*.md`，文件保留备恢复。

MCCL（MetaX Collective Communications Library）数字员工工具包：当前核心是**测试+报告一条龙**（`/mccl-test` 先调 `mccl-tester` 跑测试、再调 `mccl-reporter` 写报告），另附 GPU 门禁（`mccl-prober`）、经验同步等扩展角色。原完整开发验证流水线（含开发/编译/分发与三道独立审计卡点）的 `mccl-developer`/`mccl-supervisor` 已于本次精简移除，相关命令 `/mccl-run`、`/mccl-bench`、`/mccl-impact-run` 标注废弃。节点数可配置（1/4/8三档，见下方"节点数配置"一节），不同档位覆盖的验证范围不同。

**本仓库只存agent定义与静态自检，不产生运行产物。** 运行产物（`.mccl-runs/`）在拷贝到真实仓库、配好`mccl-env.json`之后才会出现。

## 这是什么

当前保留的子代理（完整开发流水线的 developer/supervisor 已移除，见顶部说明）：

| Agent | 职责 | 工具 |
|---|---|---|
| `mccl-tester` | 按`$MCCL_NNODES`选择拓扑：多节点（4/8，每节点8卡）跑场景A（非对称内存）+ 场景B（对称内存）两个`mpirun`测试；其余拓扑（含单节点）判为不支持、停止上报。压测参数从`mccl-env.json`的`MCCL_PERF_*`键读取（支持`mccl-perf-override.json`临时覆盖）。日志命中驱动warm reset特征（`MX_EVENTTYPE_DRIVER`/`mcErrorDriverWarmReset`）时按15分钟间隔自动重试至多5次，额度耗尽即放弃该场景、转下一个场景继续（单场景失败不中断整轮）。产出原始日志。不改代码、不重新编译。 | 含Bash |
| `mccl-reporter` | 读run目录产物，写验证报告，每个数字必须能在原始日志里找到出处，未覆盖场景标"未覆盖"不得推断。 | **无Bash**（见下） |

编排入口（当前可用）：`/mccl-test`（测试+报告一条龙）。原完整流水线入口 `/mccl-run` 已废弃（依赖已移除的 developer/supervisor），`/mccl-bench`、`/mccl-impact-run` 同样废弃。

### 关于`mccl-reporter`禁Bash

这是本工具包里最重要的一处设计，值得单独说明：报告工程师的`tools`字段里没有`Bash`，这是一道**物理隔离**，不是配置疏漏。如果报告工程师同时具备执行能力，遇到数据缺失时就有可能"跑一下补个数字"——这个临时补的实验不在开发/测试两个环节的审计链条里，审阅者看不到，事后也没人能复现。禁Bash让这种事在物理上不可能发生：报告工程师手里没有能执行命令的工具，遇到数字对不上原始日志，唯一能做的诚实动作就是写"未覆盖"。`tests/check.sh`的不变式8专门校验这一点。

## Windows 用户先看这里

这套工具包全是 bash（`source`、`ssh`、`rsync`、`docker exec`、`git rev-parse`）。**纯 PowerShell 跑不了**——PowerShell 不认 `source`，agent 开工第一步 `eval "$(python3 mccl-env-load.py)"` 就失败，后面全塌。你需要一个 bash 环境。

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

装完在 **WSL 终端里**（不是 PowerShell）装 Claude Code、启动 `claude`。之后 README 里所有命令照搬，只有 `mccl-env.json` 里的本地源码路径要用 WSL 写法：`"MCCL_LOCAL_SRC": "/mnt/d/workspace/..."`（D 盘在 WSL 里是 `/mnt/d`，Git Bash 里是 `/d`）。

### 让 AI 驱动：你只填配置 + 输一次密码

你不用自己敲那些 bash 命令，可以让 AI 替你跑（`mccl-setup-ssh`、`/mccl-test`、`check.sh` 它都能执行）。分工：

| 事情 | 谁做 |
|---|---|
| 填 `mccl-env.json`（节点IP、路径、容器名） | **你**，一次 |
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
cp ~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/mccl-env.json.example ./mccl-env.json
# 编辑mccl-env.json：填入MCCL_NODES、MCCL_CONTAINER、MCCL_MACA_PATH等14个raw键的真实值（loader自动派生另7个）

# 3. 配好本机到编译节点的免密（<插件根> 是什么、怎么查，见紧接着的说明）
bash <插件根>/bin/mccl-setup-ssh

# 4. 在MCCL仓库根启动claude
claude

# 5. 跑第一轮
/mccl-test
```

**必须在MCCL仓库根目录启动claude。** 子代理开工第一步都是`git rev-parse --show-toplevel`锚定`REPO_ROOT`，`mccl-env.json`、MCCL源码、`.mccl-runs/`都挂在这个根下面（`agents/mccl-tester.md`第1节）。子代理继承的是主会话启动时的工作目录，不是它自己猜的路径——虽然在仓库子目录里启动`git rev-parse --show-toplevel`也能解析出仓库根，但主控在`commands/mccl-test.md`第2节里把`RUN_DIR`拼成`$REPO_ROOT/.mccl-runs/...`并作为绝对路径传给每个子代理；如果你在别的目录启动、又手动`cd`过仓库，容易在"我以为的仓库根"和"实际解析出的仓库根"之间产生认知错位，导致你后面手动拼路径（例如下方场景化调用时）对不上。最省心的做法就是老老实实在仓库根启动。

### `<插件根>`是什么、怎么查

README里凡是写`<插件根>`的地方（如`bash <插件根>/bin/mccl-setup-ssh`），指的都是**这套工具包的文件实际落地的那个目录**——里面有`agents/`、`commands/`、`references/`、`bin/`、`tests/`、`mccl-env.json.example`。它不是固定值，取决于你用哪种装法，所以写成占位符：

- **插件装法**：`~/.claude/plugins/marketplaces/<某目录>/plugins/mccl-digital-employee/`。`<某目录>`因add方式而不同，别硬记。
- **拷贝装法**：你`git clone`到的地方，如`~/mccl-digital-employee/plugins/mccl-digital-employee/`。

**不用猜，一条命令查出来**（找那个装着`references/`的目录）：

```bash
find ~/.claude/plugins ~ -maxdepth 8 -name mccl-safety.md 2>/dev/null | sed 's|/references/mccl-safety.md||'
```

打印出来的就是`<插件根>`。之后凡是README让你`bash <插件根>/xxx`，把`<插件根>`换成这条查出来的路径即可。例如查出来是`~/mccl-digital-employee/plugins/mccl-digital-employee`，那么配免密就是`bash ~/mccl-digital-employee/plugins/mccl-digital-employee/bin/mccl-setup-ssh`。

**注意区分两个不同的"根"**：`<插件根>`是工具包文件所在处（你手动敲那几条命令时要填它）；`REPO_ROOT`是你的MCCL仓库根（agent运行时自己`git rev-parse`解析，不用你管）。agent跑起来后靠`bin/mccl-toolkit-root`自动定位插件根，也不用你告诉它——`<插件根>`只在**你手动执行**`mccl-setup-ssh`、`check.sh`这类命令时才需要你填。

## 安装到真实仓库

两种装法都支持，装完都还需要一步：在你的MCCL仓库（`mccl_dev_supernode`）里配好`mccl-env.json`。

### 方式一：插件安装（推荐）

在Claude Code里直接执行这两条：

```
/plugin marketplace add https://github.com/wongkq/mccl-digital-employee.git
/plugin install mccl-digital-employee@mccl-digital-employee
```

**第一条用完整HTTPS地址（`.git`结尾），别用`wongkq/mccl-digital-employee`简写。** 简写会被展开成SSH形式`git@github.com:...`，要求你这台机器配好了GitHub的SSH密钥——没配的机器会报`Permission denied (publickey)`。本仓库是公开的，HTTPS匿名可读，不碰SSH密钥，哪台机器都通。只有确认这台机器已经配好GitHub SSH密钥时，才可以用简写图省事。

第二条的格式是`插件名@marketplace名`，本仓库两者同名，所以是`mccl-digital-employee@mccl-digital-employee`。

插件装到`~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/`，agent定义、`references/`、`bin/mccl-toolkit-root`都在插件目录下，不进你的MCCL仓库。但`mccl-env.json`和MCCL源码只能在**你自己的仓库**里，这是插件装法下必须分清的两个根——细节见下方"双根模型"一节。

装完插件后，仍需在MCCL仓库根目录执行：

```bash
cp ~/.claude/plugins/marketplaces/mccl-digital-employee/plugins/mccl-digital-employee/mccl-env.json.example ./mccl-env.json
# 编辑 mccl-env.json，填入真实的节点IP、路径、容器名等14个raw键的真实值（loader自动派生另7个）

# 合并（不要覆盖）你仓库已有的 .claude/settings.json：
#   把本仓库 .claude/settings.json 里 permissions.deny 的5条规则
#   （git push / reboot / shutdown / halt / init）追加进你仓库现有的 deny 列表
#   注意：check.sh 只校验其中3条（git push / reboot / shutdown），halt / init
#   漏掉了也不会报错，合并时自己对一遍

# 追加到你仓库的 .gitignore（若已有类似条目则跳过）：
#   .mccl-runs/
#   mccl-env.json
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
cp -r $SRC/references  .    # 领域知识文档，-r 带上子目录
cp $SRC/mccl-env.json.example  ./mccl-env.json
# 编辑 mccl-env.json，填入真实的节点IP、路径、容器名等14个raw键的真实值（loader自动派生另7个）

# 合并（不要覆盖）真实仓库已有的 .claude/settings.json：
#   把本仓库 .claude/settings.json 里 permissions.deny 的5条规则
#   （git push / reboot / shutdown / halt / init）追加进真实仓库现有的 deny 列表
#   注意：check.sh 只校验其中3条（git push / reboot / shutdown），halt / init
#   漏掉了也不会报错，合并时自己对一遍

# 追加到真实仓库的 .gitignore（若已有类似条目则跳过）：
#   .mccl-runs/
#   mccl-env.json
```

这种装法下`references/`直接在项目里、`bin/`不在PATH，agent会自动退回`$REPO_ROOT`当`TOOLKIT_ROOT`——不需要额外配置，见下方"双根模型"。

### 双根模型

不管哪种装法，agent运行时都要分清两个根：

| 根 | 怎么取 | 下面有什么 |
|---|---|---|
| `TOOLKIT_ROOT` | `mccl-toolkit-root`命令（插件装法下`bin/`在PATH里），取不到就退回`$REPO_ROOT` | `references/`（领域知识）、`bin/mccl-env-load.py`（env loader） |
| `REPO_ROOT` | `git rev-parse --show-toplevel` | `mccl-env.json`、MCCL源码、`.mccl-runs/` |

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

**拷贝装法（方式二）的更新**就是普通 git：进你 clone 工具包的目录 `git pull`，再重新 `cp` 一遍到 MCCL 仓库（`agents/`、`commands/`、`references/`）。`mccl-env.json` 是你自己填的、不会被覆盖，放心。

**看当前装的是哪个版本 / 有没有加载错误**：`/plugin` → **Installed** 标签，或 `claude plugin list`。

## 平台支持：Claude Code 与 Qoder CN CLI

本工具包**同时支持 Claude Code 和 Qoder CN CLI**（阿里云，原通义灵码）。两者的插件/智能体约定在本仓库里是同一份布局：

| 仓库里的东西 | Claude Code | Qoder CN CLI |
|---|---|---|
| `.claude-plugin/marketplace.json` | ✅ marketplace 索引 | 忽略 |
| `.qoder-plugin/plugin.json`（`plugins/mccl-digital-employee/` 下） | 忽略 | ✅ 插件 manifest（`plugins install` 直接装目录） |
| `agents/*.md`（frontmatter `name`/`description`/`tools`） | ✅ 子代理 | ✅ Subagent（同格式，`tools` 支持逗号分隔串） |
| `commands/*.md`（frontmatter `name`+`description`） | ✅ 斜杠命令（只读 `description`，忽略 `name`） | ✅ Prompt 命令（要求 `name`+`description`） |
| `bin/` | ✅ 脚本 | ✅ 插件约定目录 |
| `.claude/settings.json` deny | ✅ 本机命令护栏 | ❌ 不读取（Qoder 用自己的权限配置，见下） |

**Qoder CN CLI 安装**（本仓库不依赖 marketplace，插件本体是目录，直接装）：

```bash
qoderclicn plugins validate <工具包根>/plugins/mccl-digital-employee   # 结构自检
qoderclicn plugins install <工具包根>/plugins/mccl-digital-employee
qoderclicn plugins list          # 确认装上
qoderclicn agents list           # 看 9 个子代理是否注册
# TUI 里 /commands 看 6 个命令；改动后 /agents reload、/commands 重载
```

**两个已知的平台差异（不影响主流水线，但要知情）**：

1. **权限护栏只对 Claude Code 生效。** `.claude/settings.json` 的 deny（`git push`/`reboot`/`shutdown`/`halt`/`init`）是 Claude Code 的机制，Qoder 不读取它——Qoder 下这些护栏只靠 agent 提示词硬禁令一层软约束补位（本仓库的分层防御本来就如此设计，只是 Claude Code 多了一层 harness 强制）。想在 Qoder 下补硬护栏，用 Qoder 自己的权限配置（如 Subagent 的 `permissionMode`）另行配置。
2. **hooks 不互通。** `.claude/settings.local.json` 的 timing 钩子是 Claude Code 的；Qoder 用插件内的 `hooks/hooks.json`。timing 日志只是开发期自测工具，不影响插件功能。

插件根定位（`bin/mccl-toolkit-root`）三路兼容：优先 `$QODER_PLUGIN_ROOT` 或 `$CLAUDE_PLUGIN_ROOT`（谁被设置且有效用谁），都无效则用 `$BASH_SOURCE` 反推——所以两种装法、两个平台都能定位到 `references/`。`tests/check.sh` 不变式11 三路自举校验、不变式28 守护命令 `name` 字段，双端兼容性被静态不变式持续保证。

## 换机器 / 换节点IP

IP变了只改一个文件：`mccl-env.json`（不入库）。改完跑一次：

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
> 8节点配置下，这个自检脚本的检查条数与`$MCCL_NODES`实际的节点数对不上，
> 需要人工判断脚本报的"不通"是不是真的问题，而不能完全依赖它的退出码。

### 为什么不把密码写进配置文件

这套agent产出的日志是"完整原始输出，不摘要、不裁剪"（报告工程师要靠它核对数字出处）。
一旦命令行里出现`sshpass -p '密码'`，密码就会进`build.log`/`test-*.log`；
报告工程师读这些日志、报告可能被归档到`docs/reports/`——
而那个目录是入库的。密码就这样从配置文件走进了git记录。`ps aux`也会暴露它。

换机器的成本本来就只有一条`ssh-copy-id`，为省这一条命令去新增一条泄漏路径，不划算。

## 节点数配置

改节点数只改`mccl-env.json`两个键（空格分隔，第一个必须是编译节点）：

```json
"MCCL_NODES": "<node0-ip> <node1-ip> ...",
"MCCL_GPUS_PER_NODE": 8
```

`MCCL_NODE0_IP`、`MCCL_NNODES`、`MCCL_NP`、`MCCL_HOST_SPEC`都由`bin/mccl-env-load.py`从这两个键派生，不需要、也不应该手填（`tests/check.sh`不变式12会跑两个输入验证这几个派生量确实随`$MCCL_NODES`变化、非写死）。

**只支持两档节点数**（单节点冒烟场景已于 2026-08 移除——它对跨节点对称内存路径没有诊断能力，只保留真实多节点测试），因为MCCL的拓扑常量（`nNodes`/`nodeSize`/`extLsaSize`）由`devrOamNodeCount()`硬编码返回，只认OAM32（4节点）和OAM64（8节点）两种形态。但这两种形态还有一个隐含前提：`nodeSize=8`同样是硬编码值，由PCIe Switch硬件结构决定，代码里没有按`$MCCL_GPUS_PER_NODE`重新计算。所以拓扑校验同时看节点数和每节点卡数，**能测对称内存的组合只有(8卡,4节点)和(8卡,8节点)**：

| `$MCCL_NODES`个数 | `$MCCL_GPUS_PER_NODE` | 拓扑 | 测什么 | 不测什么 |
|---|---|---|---|---|
| 4 | **8** | OAM32 | 场景A（非对称内存，`$MCCL_PERF_BIN_ASYM`）+ 场景B（对称内存，`$MCCL_PERF_BIN_SYM -R 2`）两个32卡`mpirun`测试，`extLsaSize=11` | 无（这是本工具包原本针对的完整拓扑） |
| 8 | **8** | OAM64 | 同OAM32，`-np 64`，`extLsaSize=15` | 无 |
| 4 或 8 | `!=8`（如"4节点2卡"） | **不支持** | 不跑 | 全部——节点数达标但每节点卡数不是8，代码里硬编码的`nodeSize=8`/`GROUP=8`与实际拓扑对不上，对称内存路径同样不会按设计启用，与下面"其他节点数"档是同一条fallback逻辑，归入同一档处理 |
| 其他节点数（1/2/3/5/6/7/9+...） | 任意 | **不支持** | 不跑 | 全部——`CliqueManager::IsSupported()`的OAM32分支不匹配这些节点数，对称内存路径不会启用，会静默fallback到Ring/Tree。在这种拓扑下继续跑比不跑更有害：会产生一份看起来"跑通了、有perf数据"的报告，但报告里的数字压根没测到对称内存路径。测试子代理开工时会先做拓扑合法性校验，遇到这两档**停止并上报，不跑任何mpirun**（见`agents/mccl-tester.md`，闷头跑了也是白跑） |

**本次节点数可配置化改造未覆盖的部分**：`bin/mccl-setup-ssh`（免密自检脚本）仍然硬编码检查"编译节点 → 3个其余节点"这一固定形态，只对4节点配置准确；`tests/check.sh`只验证`mccl-env.json.example`+loader 的派生关系，不验证agent在真实8节点集群上的实际行为（这一点与已知限制第1条一致，本身就是本仓库的固有边界，不是本次改造新引入的）。

## 编译模式：容器 vs 无容器

改编译模式只改`mccl-env.json`一个键（填容器名=容器模式；留空字符串`""`=无容器模式）：

```json
"MCCL_CONTAINER": "<container-name>"
```

| `MCCL_CONTAINER` | 模式 | 编译在哪跑 | 前提 |
|---|---|---|---|
| 非空（如`"zb"`） | 容器模式（现状） | 编译节点（`$MCCL_NODE0_IP`）上的容器内，远程命令套`docker exec $MCCL_CONTAINER bash -c` | 容器已建好、镜像里已装好MACA SDK与工具链 |
| 空字符串`""` | 无容器模式 | 编译节点宿主机，远程命令用`bash -lc`（登录shell，不套`docker exec`） | 宿主机上装好完整MACA SDK，且工具链（mxcc、cu-bridge）能被登录shell的`~/.bashrc`等加载到`PATH`——这是硬前提，无容器模式下没有容器替你准备环境 |

判断方式agent一律用`[ -n "$MCCL_CONTAINER" ]`，为真即容器模式。两种模式在功能上等价：拓扑校验、编译陷阱（macaify增量缓存、`MACA_PATH`选型）、md5契约（`$MCCL_NNODES + 1`份全部一致）都不因模式而变，唯一差别是远程命令是否多套一层`docker exec`。无容器模式下分发链路更简单——没有容器内外之分，编译产物直接在宿主机文件系统里，原本容器模式"两个`docker exec cp`动作"合并成一条普通`cp`（详见`references/mccl-remote-ops.md`第0.1、1、3节，`references/mccl-build-pitfalls.md`第2、3节）。

## 用法

七条入口命令，按场景选（自然语言"测试/复测/回归"会路由到 `/mccl-test`，不会触发开发）：

| 你要做什么 | 命令 |
|---|---|
| 改完代码要验证 pass/fail（跑2固定场景，服务 commit 决策） | `/mccl-run`【已废弃，依赖已移除的 developer/supervisor】 |
| 库已编好分发好，复测+出报告（不改代码、不重编） | `/mccl-test [<run目录>]` |
| 想知道改了哪、影响什么、测什么算数 | `/mccl-impact-run`【已废弃】 |
| 性能评估/对比（多场景矩阵、多轮统计、--compare 前后库对比） | `/mccl-bench`【已废弃】 |
| GPU 忙，想提交后让系统排队空闲再跑 + 夜间定时 | `/mccl-bench-queue submit/status/pause/stop/resume` |
| 加了坑/场景/模板想一键推给同事 | `/mccl-skill-sync`（手动批） / `/mccl-skill-sync auto` |
| 日常验证 GPU 环境（不跑业务，只看拓扑/占用/带宽达标） | `bash plugins/.../bin/mccl-gpu-probe --mode full` |

**路由规则**：用户说"测试/复测/跑一遍测试/回归"而没提改代码 -> 用 `/mccl-test`（测完自动出报告，不开发）。原 `/mccl-run`（改代码->上集群验证->出报告完整闭环）已废弃；如需改代码后验证，需手动完成开发/编译/分发后再用 `/mccl-test` 测试+出报告。

下面按顺序讲清每条命令怎么用。`/mccl-run`、`/mccl-impact-run`、`/mccl-bench` 已废弃（见各节标注），`/mccl-bench-queue`、`/mccl-skill-sync` 细节见后方各自小节。

### `/mccl-run`【已废弃】

> ⚠️ 已废弃：编排依赖已移除的 `mccl-developer`/`mccl-supervisor`，现状态下执行会在调度阶段失败。文件保留备恢复，完整内容见 `commands/mccl-run.md`。测试+报告改用 `/mccl-test`。

### 测试+报告

库已编好、已分发好，想复测并直接拿到验证报告：**`/mccl-test [<run目录>]`**。这是当前主入口，测完自动出报告，不调开发、不改码/编译/分发。

- `<run目录>`：可指定已有 run 目录（`.mccl-runs/<ts>` 根目录取其最新 `attempt-N/`，或直接给 `attempt-N/` 目录），不指定则新建 `.mccl-runs/<ts>/attempt-1/`。
- 会做：`git diff` 生成 `change.patch`（作报告变更基准；工作区无改动则为空，报告标注"纯回归"）；**下发即输出六字段执行摘要**（执行时间/前置分发/测试规模/产物目录/MD5基准/测试命令，`commands/mccl-test.md` §3.5，其中前置分发是主控的只读md5预览，判据仍是tester的独立核对）；调 `mccl-tester` 按`$MCCL_NNODES`选场景、独立核对`libmccl.so`各节点md5、跑`mpirun`、产出原始日志与`test-result.md`；再调 `mccl-reporter` 读全部产物写 `report-1.md`，`cp` 成 `final-report.md`。测完无论 PASS/FAIL 都出报告。
- 不会做：改代码、改库、重新编译、分发、commit。
- 产物：`test-result.md`（测试结论）+ `final-report.md`（验证报告），主控会输出两者绝对路径并一句话转述结论。

若只想测、不要报告，可跳过 `/mccl-test` 直接手动调 `mccl-tester`（提示词必须给绝对路径的 run 目录——子代理继承主会话CWD，给相对路径会写到别处去）。示例：

```
用mccl-tester子代理跑一次测试。
run目录：/home/xxx/mccl_dev_supernode/.mccl-runs/2026-07-17-1030/attempt-1
产出写到该目录：test-preflight.md、test-asymmetric.log、test-symmetric.log、
test-result.md。
```

### 只审计【已废弃】

> ⚠️ 独立审计子代理 `mccl-supervisor` 已移除，本节为其历史用法。文件保留备恢复，完整内容见 `commands/mccl-run.md`。

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
└── attempt-1/
    ├── change.patch                 # git diff，报告变更基准（工作区无改动则为空）
    ├── test-preflight.md            # 测试前置核对
    ├── test-asymmetric.log          # 场景A日志
    ├── test-symmetric.log           # 场景B日志
    ├── [test-*.retry-<k>.log]       # 仅驱动warm reset重试时出现，第k次重试的原始日志
    ├── test-result.md               # 测试结论（PASS/FAIL）
    ├── [test-anomaly.md]            # 仅异常时出现
    ├── report-1.md                  # 验证报告（mccl-reporter 产出）
    └── final-report.md              # report-1.md 的拷贝，最终报告
```

`/mccl-test` 单次测试单次报告，产物都在 `attempt-1/` 下；若指定已有 run 目录复测，取其最新 `attempt-N/`。

## 怎么读产物

- **`test-result.md`**--测试结论（PASS/FAIL），最先看这个。
- **`final-report.md`**--验证报告，`report-1.md` 的拷贝，每个数字标出处（文件名+行号），未覆盖场景标"未覆盖"。
- **`test-preflight.md`**--测试没跑起来时先看这个。首部为执行摘要（执行时间/前置分发/测试规模/产物目录/MD5基准/测试命令，tester 本轮实际核对值），随后是七条checklist（`agents/mccl-tester.md`第4节，含压测参数与override覆盖状态记录），哪条没过、怎么核对的都写在里面。
- **`test-*.log`**--原始日志，完整输出不摘要不裁剪。
- **`[test-anomaly.md]`**--仅异常时出现，记录 hang/SegFault 等。

## 重试与卡点速查表【已废弃】

> ⚠️ 本节描述的是 `/mccl-run` 的 attempt/编译内循环/报告内循环与 REWORK 打回机制，依赖已移除的 `mccl-developer`/`mccl-supervisor`。`/mccl-test` 不含这些循环（单次测试+单次报告）。完整内容见 `commands/mccl-run.md`（已标注废弃）。

## GPU环境门禁（mccl-prober）

`mccl-prober` 是 **GPU 环境门禁** agent：核对 GPU 是否真的存在、健康、空闲、带宽达标，再决定是否铺 32 卡测试，避免铺到 GPU 正忙或正在报错的节点上空跑一轮。`/mccl-bench-queue` 调度任务时也会先用它探测环境是否 READY。

**怎么跑的**：`mccl-prober` 调 `bin/mccl-gpu-probe --mode full`，复用仓库根的 `gpu_health_check.sh` 作带宽/健康引擎（scp 到 NODE0 跑、报告拉回本地解析），补占用检测（mx-smi 进程列表，任一卡有进程即占用）与 bin 就绪核对，产出 `<run>/attempt-<N>/{gpu-preflight.md, gpu-verdict.json}`。带宽按 run 缓存（`<run>/.bw-cache/`，跨 attempt 复用），占用每轮重查。

**三态行为**（主控只读 `gpu-verdict.json` 的 `verdict` 字段）：

| verdict | 含义 | 主控动作 | 递增 attempt |
|---|---|---|---|
| READY | 全绿（带宽 WARN 仍算 READY，标告警） | 进 tester | 否 |
| NOT_READY | 占用/带宽FAIL/bin缺/拓扑不符 | 停，报告 failures，等环境 | 否 |
| error | 探测自身出错（ssh 不通/mxvs 缺/脚本崩） | 停，报告出错 | 否 |

**三态都不消耗测试预算**--门禁是环境问题，NOT_READY 等下轮不跑测试。

**已知限制**：
- 占用判定"有进程即占用"是最严判定。集群若有常驻监控/守护进程占某卡，**交互式门禁会恒 NOT_READY**（预留白名单/PID 过滤作为未来收紧项，v1 不做）。**定时任务链路不受此困**：调度循环探测带 `--free-occupied`，遇占用先 kill 占用进程再复查（见下方"调度器怎么跑"），清理后空闲即照常派发。
- `gpu_health_check.sh` 已脱敏并入库：默认 `HOSTS=()` / `SSH_PASS=""`（占位），真实主机与密码由调用方经 `--hosts <csv>` / `GHC_HOSTS` / `GHC_SSH_PASS` 注入。打包脚本 `bin/mccl-gpu-probe` 照常全用 `$MCCL_*`，自身无 IP/密码。严禁把真实主机/密码写回 `gpu_health_check.sh` 后再提交。
- mx-smi 占用判定的输出格式假设仿 nvidia-smi 的 `Processes:` 段，需在真实硬件上校准；探测器的远程执行行为本仓库无法端到端验证，首用建议人工盯一轮。

## 测试矩阵与前后对比（/mccl-bench）【已废弃】

> ⚠️ 已废弃：依赖已移除的 `mccl-developer`/`mccl-supervisor`。文件保留备恢复，完整内容见 `commands/mccl-bench.md`。

## 环境排队与定时任务（/mccl-bench-queue）

GPU 繁忙时 `/mccl-bench` 会因环境不就绪失败。`/mccl-bench-queue` 提供任务排队：提交后调度器每 5 分钟探测 `MCCL_NODES`，环境 READY 才跑，NOT_READY 等下轮。夜间定时也走同一队列。

**提交任务**：`/mccl-bench-queue submit <任务描述> --rounds 3 --compare`
- 返回 task_id，任务入队（status=PENDING）
- 调度器（`bin/mccl-queue-scheduler`，cron 每 5 分钟触发）对排头任务调①prober 探测：READY 交②⑤`/mccl-bench` 跑、NOT_READY 等下轮

**控制**：
| 命令 | 作用 |
|---|---|
| `/mccl-bench-queue status` | 查看队列（task_id/status/进度） |
| `/mccl-bench-queue pause` | 全局暂停（调度器下轮跳过） |
| `/mccl-bench-queue stop <task_id>` | 终止任务（/mccl-bench 完成后生效） |
| `/mccl-bench-queue resume` | 恢复调度 |

**定时任务（⑦）**：用 CronCreate 注册夜间定时，到点提交预设场景进同一队列：
```
# 例：每晚 23:00 提交夜间对称内存回归
CronCreate cron="3 23 * * *" prompt="/mccl-bench-queue submit 夜间对称内存回归 --rounds 5 --compare"
```
提交后进同一队列，调度器 5 分钟轮询消费。

**调度器怎么跑**：`bin/mccl-queue-scheduler`（无参数=调度循环）被 cron 触发时：flock 加锁 -> 读 `.mccl-bench-queue/queue.json` -> 检查 pause/stop 标志 -> 调 prober 探测（**带 `--free-occupied`**：遇 GPU 被占用先 kill 占用进程再复查一次，任务不再因外部进程占用而无限 WAIT。仅限 `$MCCL_NODES` 上的 GPU 占用进程；本流水线自身的 `mpirun`/`all_reduce_perf` 进程与 PID≤1 跳过不杀；每次 kill 与跳过逐条记入 `gpu-verdict.json` 的 `occupancy.killed`，清理后仍占用照旧 WAIT。约束见 `references/mccl-safety.md` 第9条例外；交互式 `mccl-prober` 不传该参数、仍只读上报）-> READY 输出 `DISPATCH:<task_id>:<params>` 交 Claude 跑 `/mccl-bench` -> NOT_READY 输出 `WAIT` 等下轮。无状态、崩溃下轮 cron 恢复。

**CronCreate 调度提示**（注册 cron 时用这个 prompt 触发调度循环）：
```
运行 bash bin/mccl-queue-scheduler。读取输出：
- DISPATCH:<task_id>:<params> -> 运行 /mccl-bench <params>，完成后运行 bash bin/mccl-queue-scheduler complete <task_id> DONE（读 verdict-bench.md：PASS=DONE，REWORK/ABORT=FAILED；若 stop-<task_id>.flag 存在则 STOPPED）
- WAIT/STOP/SKIP -> 无事可做
```

**已知限制**：
- stop 实时性是分钟级（/mccl-bench 完成后检查 stop flag，v1 不中途杀场景）。需秒级要 daemon（已弃）。
- CronCreate recurring 任务 7 天自动过期（harness 限制），需定期重注册或改系统 cron（`crontab -e`）。
- 单任务串行（flock + 排头消费），不支持多任务并行（避免争 GPU）。
- prober 连续 12 轮（1 小时）error 才判 FAILED（不轻易因临时抖动判死）。
- scheduler 的 cron/flock/prober/派发远程行为本仓库无法端到端验证，首用建议人工盯一轮。

## skill 经验同步（/mccl-skill-sync）

你在本仓库里加了坑、场景、模板，想同步给其他人。手动模式给你看 diff 清单、你批准后执行；自动模式供 CronCreate 定时（全部已跟踪修改自动 commit+push，无人值守）。

**手动**：`/mccl-skill-sync`
> 先列「文件-状态-改动量-你估是什么经验」清单，你批准后才执行 commit+push。

**自动**：`/mccl-skill-sync auto`
> 经 `tests/check.sh` 硬闸门 → `git add -u`（只收已跟踪修改，绝不自动打包 untracked 新文件）→ commit → push 到每个已配置远端。供CronCreate 注册：`CronCreate cron="0 18 * * *" prompt="/mccl-skill-sync auto"`。

**safety 第 4 条已改**：`git push` 只属于 `mccl-skill-sync` 的本职（同步是它本职工作）；其他 agent（含主控）一律禁止。**注意这里的"允许"是提示词层的分工，不是 harness 放行**：`.claude/settings.json` 的 `Bash(git push:*)` deny（`tests/check.sh` 不变式5强制要求保留）对所有 agent（含 skill-sync）生效，skill-sync 执行 push 时命令会被拦下——被拦时它不重试、不绕过，把具体 push 命令打给你手动执行（和 `mccl-setup-ssh` 配密钥同一交互模式），输出 `SYNC:push-blocked`。这是设计：push 动作经 skill-sync 之手交到人面前，天然多一道人工把关。

**已知边界**：
- push 失败：commit 留在本地不动、不自动重试（重试是你的判断，不是 agent 的）。
- 不处理合并冲突、不设 git config（user.email/name 缺失就停）、不擅自 pull。
- CronCreate recurring 7 天过期，需定期重注册或改系统 cron（同⑥⑦）。
- 自动模式的对话批准无法本地验证；静态不变式24/25（agent 链闭合/命令 auto 入口）每轮主跑。

## 影响驱动验证（/mccl-impact-run）【已废弃】

> ⚠️ 已废弃：依赖已移除的 `mccl-developer`/`mccl-supervisor`。文件保留备恢复，完整内容见 `commands/mccl-impact-run.md`。

## 出问题怎么查

| 现象 | 原因 | 怎么办 |
|---|---|---|
| agent卡住不动、ssh没反应 | 密钥没配好，裸ssh弹密码提示，而agent背后没有人输密码 | 跑`bash <插件>/bin/mccl-setup-ssh`。所有ssh已带`$MCCL_SSH_OPTS`（`BatchMode=yes`）会立刻失败而不是挂起（`references/mccl-remote-ops.md`§0.5），若仍挂起说明有裸ssh漏网，跑`bash <插件>/tests/check.sh`第13条排查 |
| preflight md5不一致，测试不跑（多节点模式第2条） | **最常见**。编译节点`$MCCL_MACA_LIB_DIR/libmccl.so`没更新 | 这是`测试.md`原始工作流的洞：它记载的分发只有三条scp（发给非编译节点）加编译节点容器内到`/opt/maca/lib`的cp，编译节点的`$MCCL_MACA_LIB_DIR`从没写过，且全程只有`make -j50`没有`make install`。补`references/mccl-remote-ops.md`第3节"动作②"那条命令：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'cp $MCCL_REMOTE_SRC/build/libmccl.so $MCCL_MACA_LIB_DIR/'"` |
| agent说"找不到references/" | `TOOLKIT_ROOT`没解析对 | 插件装法应由`bin/mccl-toolkit-root`解析（优先`$QODER_PLUGIN_ROOT`/`$CLAUDE_PLUGIN_ROOT`，兜底`$BASH_SOURCE`反推）；拷贝装法退回`$REPO_ROOT`。确认`references/`确实在插件根或仓库根下（`bin/mccl-toolkit-root`） |
| 主控直接停，提示`mccl-env.json`不存在 | 没从`.example`拷贝 | `cp <插件>/mccl-env.json.example ./mccl-env.json`并填值（`commands/mccl-test.md`第1节） |
| agent拒绝执行，说拓扑不受支持 | `MCCL_NNODES`不是4/8（含单节点），**或**每节点卡数`MCCL_GPUS_PER_NODE`不是8而节点数是4/8（如"4节点2卡"） | 能测对称内存的组合只有 (8卡,4节点) 和 (8卡,8节点)——`nodeSize=8`是PCIe Switch硬件决定、代码硬编码的。偏离这个的配置，`CliqueManager::IsSupported()`不匹配，对称内存不启用、静默fallback到Ring/Tree，**测出来的不是你以为在测的东西**，拒绝比跑更安全。单节点冒烟场景已于 2026-08 移除，配置1个节点同样会被拒绝（`agents/mccl-tester.md`第2节） |
| 报告里写"缺失"，日志明明跑了 | 日志落在远端了 | `ssh`的重定向必须在引号**外面**：`ssh $MCCL_SSH_OPTS root@$MCCL_NODE0_IP "<命令>" > "$RUN_DIR/build.log" 2>&1`，写成`ssh ... "<命令> > build.log 2>&1"`日志就留在远端（`references/mccl-remote-ops.md`§0.6）。`mccl-reporter`没有Bash、取不了远程文件，日志不在本地对它等同不存在 |
| mpirun hang（判定见 `mccl-tester.md` §5） | 见`test-anomaly.md` | **禁止重启**（`references/mccl-safety.md`第3条）。agent会采`dmesg`+IB状态后停下等你（`agents/mccl-tester.md`第5节）。你也别手动重启——这条是`测试.md`原始规程里的硬禁令 |
| 日志里出现 `MX_EVENTTYPE_DRIVER data: ResetType=1, ResetCause=1` / `mcCtxGetCurrent: Returned mcErrorDriverWarmReset` | 驱动warm reset（已知故障模式中唯一自动重试的一类） | agent会自行按15分钟间隔重试同一命令至多5次（`agents/mccl-tester.md`第5节重试规程），每次尝试（含重试）的记录都在`test-result.md`，重试日志为`test-*.retry-<k>.log`。5次均失败则该场景判FAIL并转去跑另一个场景--单场景失败（含其他故障，如SegFault）不中断整轮，两个场景各自独立判定；但hang例外，hang仍按原规程整轮停止 |
| 定时任务一直 WAIT，提示环境未就绪 | GPU 被外部进程占用（或带宽/bin/拓扑问题） | 调度循环探测带 `--free-occupied`：外部占用进程会被自动 kill（term，10 秒存活再 kill -9）后复查，清干净即派发。仍 WAIT 说明占用清不掉（本流水线自身进程、PID≤1、或非占用原因）--查 `.mccl-bench-queue/scheduler.log` 与 `probe-*.json` 的 `occupancy.killed`，kill 明细都在里面。**交互式**探测（`mccl-prober`/手动跑 `mccl-gpu-probe`）不杀进程只上报，要清需自己处理 |
| SegFault | 已知故障模式 | 查`MCCL_P2P_LEVEL`是否与固件匹配（`agents/mccl-tester.md`第6节）。该场景判FAIL后继续跑另一场景，不中断整轮 |
| UDS Connection refused | 已知故障模式 | 确认`$MCCL_MACA_PATH`的`mcMemFabricHandle_t`是1112字节版本，不是80字节旧版stub（`agents/mccl-tester.md`第6节、`mccl-env.json.example`的 `_comments.maca_path`） |

## 各角色边界速查

| 角色 | Bash | 能连测试机 | 能做什么 | 不能做什么 |
|---|---|---|---|---|
| `mccl-tester` | 有 | 能（ssh到全部节点、跑mpirun） | 按`$MCCL_NNODES`选场景跑测试、独立核对md5、产出原始日志 | 不改代码、不改库、不重新编译（`agents/mccl-tester.md`第5节） |
| `mccl-reporter` | **无** | **不能** | 读run目录已落盘产物，写报告，每个数字标出处，未覆盖场景标"未覆盖" | 不能执行任何命令去补数据——`tools`里没有Bash，这是防报告造假的**物理隔离**，不是疏漏（`agents/mccl-reporter.md`第1节、`tests/check.sh`不变式8） |
| 主控（`/mccl-test`） | 有限（`mkdir`/`date`/`git diff`/`cp`/只读`md5sum`预核对（§3.5执行摘要用）等） | 不直接连 | 生成`change.patch`、下发即输出执行摘要（六字段，含各节点libmccl.so只读md5预览）、调度`mccl-tester`测试、调度`mccl-reporter`写报告、`cp`成`final-report.md` | 不代劳子代理的活（不改代码、不编译、不跑mpirun、不写`test-result.md`/`report-N.md`）；md5只做预览不代替tester独立核对；不自动commit（`commands/mccl-test.md`第0节） |

## 目录结构

本仓库是marketplace布局，插件本体在`plugins/mccl-digital-employee/`下：

```
.claude-plugin/marketplace.json      marketplace索引
.claude/settings.json                权限deny规则模板（git push / reboot / shutdown / halt / init），
                                      插件带不走，留给用户合并进自己仓库
plugins/mccl-digital-employee/
├── .claude-plugin/plugin.json       插件清单
├── bin/
│   ├── mccl-toolkit-root            输出TOOLKIT_ROOT（双根模型的关键）
│   ├── mccl-env-load.py             加载mccl-env.json、算7个派生量
│   ├── mccl-setup-ssh               免密自检（本机→NODE0链路）
│   ├── mccl-gpu-probe               GPU环境探测原语（topology/占用/bin/带宽→gpu-verdict.json）
│   ├── mccl-bench-stats.py          bench性能聚合纯函数（mean/min/max→bench-stats.json）
│   └── mccl-queue-scheduler         bench队列调度器（flock+cron触发）
├── agents/
│   ├── mccl-tester.md               测试（preflight+mpirun场景A/B）
│   ├── mccl-reporter.md             报告（禁Bash，物理隔离）
│   ├── mccl-prober.md               GPU环境门禁
│   ├── mccl-bench-planner.md        性能场景规划
│   ├── mccl-bench-runner.md         性能矩阵执行+聚合
│   ├── mccl-impact-planner.md       影响驱动验证规划
│   └── mccl-skill-sync.md           经验同步（唯一允许git push的角色）
├── commands/         mccl-run / mccl-test / mccl-bench / mccl-bench-queue / mccl-gpu-info / mccl-impact-run / mccl-skill-sync
├── references/
│   ├── mccl-domain.md               领域知识（对称内存、FC kernel等）
│   ├── mccl-build-pitfalls.md       编译陷阱（含macaify增量编译坑）
│   ├── mccl-safety.md                硬禁令（10条，违反则ABORT或REWORK）
│   ├── mccl-remote-ops.md            远程调用模式手册（ssh跳板、docker exec引号嵌套、按$MCCL_NODES循环的分发差异）
│   └── bench-report-template.md     /mccl-bench 报告模板
├── mccl-env.json.example  14个raw键模板（_comments 带详细说明）
└── tests/check.sh          27条静态不变式自检（仓库级+插件级）
docs/superpowers/{specs,plans}/      设计与实施计划
```

## 已知限制（诚实列出，不淡化）

1. **本仓库连不上远程节点，agent的远程执行行为从未端到端验证过。** `tests/check.sh`只验静态不变式（frontmatter是否合法、`mccl-reporter`确实没有Bash、环境变量引用是否闭合、已跟踪文件无私网IP字面量、`测试.md`不在git历史中、有没有裸ssh漏网），**不验agent行为**——测试agent会不会真的拒绝跑不支持的拓扑、报告agent会不会真的把缺数字标"未覆盖"，这些都没有被验证过，因为验证它们需要真实的远程节点和真实的32卡集群，本仓库不具备。**首次在真实仓库使用，建议人工盯完整一轮**，逐步核对子代理落盘的产物（`test-result.md`、`final-report.md`），而不是直接放手跑。

2. **`.claude/settings.json`的deny规则只能拦截本机命令，拦不住隧道内命令。** deny列表按命令前缀模式匹配，例如`Bash(reboot:*)`能拦住本机直接执行`reboot`。但`ssh host "reboot"`在harness眼里匹配的是`Bash(ssh:*)`这个前缀，不是`reboot`本身，deny规则识别不到隧道内实际执行的命令，拦不住。这类风险目前只能靠 agent 提示词里的硬禁令（`references/mccl-safety.md`）补位，没有 harness 强制。

3. **`references/`里的领域知识来自`测试.md`的提炼，可能有偏差，且反映的是某一时间点的环境状态。** `测试.md`本身是私有材料（不入库，见下），记录的编译路径选型、拓扑常量、内核选型边界等信息对应的是提炼那一刻的真实环境。如果真实仓库所在的硬件拓扑、MACA版本、内核路径发生变化，`references/`里对应的内容需要人工同步更新，工具包本身不会自动感知环境漂移。

4. **`$QODER_PLUGIN_ROOT`/`$CLAUDE_PLUGIN_ROOT`在agent提示词正文里是否会被展开，官方文档未说明、本工具包未实测。** 这不是"验证过它不work"，而是一个未知数——我们没有找到官方文档明确保证agent的Markdown提示词正文（而非仅limited于hook/MCP配置等场景）里出现的插件根环境变量会被harness展开成实际路径。为了不把整套双根模型建在一个不确定的行为上，`bin/mccl-toolkit-root`把两个插件根环境变量当成"如果有就优先用"的加分项，但不依赖它们——真正兜底的是用`$BASH_SOURCE`反推`../`，这条路径在两种装法下都能从脚本自身的实际位置推出正确答案，不依赖任何环境变量是否被展开。这是绕开了一处不确定性，不是确认了它一定不work或一定work。

5. **8节点拓扑下，agent的实际行为同样从未端到端验证过（与第1条同一根因）。** 节点数可配置化改造改的是agent提示词里的判断逻辑（按`$MCCL_NNODES`选分支）和`mccl-env.json.example`+`bin/mccl-env-load.py`的派生关系，`tests/check.sh`能验证的也仅限于派生量本身算对了（不变式12）——拓扑不支持时测试agent会不会真的停止而不是"顺手跑一下"、8节点（OAM64）下`-np 64`与`extLsaSize=15`的实际行为，这些都需要真实8节点集群才能验证，本仓库同样不具备。`bin/mccl-setup-ssh`目前也只对4节点配置的免密链路做了针对性检查，未随本次改造同步扩展（见上方"节点数配置"一节末尾）。

6. **压测参数已外置（2026-08），但参数合法性边界靠 loader 的基础校验，不验语义。** `all_reduce_perf`的`-b/-e/-f/-n/-w/-c/-o/-d/-G`九个参数从`mccl-env.json`的`MCCL_PERF_*`键（或`mccl-perf-override.json`覆盖）拼成`$MCCL_PERF_ARGS`。loader 只校验"整数键必须是整数、override 只许出现已知 perf 键"，不校验参数组合的语义合理性（比如`-c 0`关掉正确性校验、`-n 1`失去压测意义、`BEGIN > END`），也不校验 override 文件是否被遗忘而长期生效——后者靠 tester 在`test-preflight.md`里逐键记录覆盖来源、`/mccl-test`收尾打印覆盖清单来对冲，但前提是人会去读。改参数时想清楚再改。

## `测试.md`不入库

`测试.md`是私有参考资料（真实环境的调试记录、内网IP、主机映射等），永远不进入本仓库的git历史，已在`.gitignore`中拦截。`references/`下的四份领域知识文档是从`测试.md`提炼出的技术知识（编译陷阱、硬禁令、远程调用模式、对称内存等领域概念），环境相关的具体值统一收敛到`mccl-env.json`（不入库，只提交`mccl-env.json.example`模板）。

**这条边界只有一部分是自动校验的，其余靠人工把关**——说清楚哪部分是哪部分，比笼统说"已校验"有用：

| | 谁来把关 |
|---|---|
| 内网IP字面量 | `tests/check.sh`不变式3自动校验（已跟踪文件grep私网IP段） |
| `测试.md`本身不入库 | 不变式1（不在git历史）、不变式2（被`.gitignore`拦截）自动校验 |
| `mccl-env.json`不入库 | 不变式4自动校验 |
| 主机名/末位八位组映射（如`Host3=<末位八位组>`） | **无自动校验**，靠review。写进已跟踪文件，`check.sh`照样全绿 |
| 真实文件系统路径 | **无自动校验**，且`references/`里**确实含**真实路径 |

关于最后一行：`references/`里出现`/opt/maca`这类厂商标准安装路径是**有意保留**的说明性上下文——不写清楚"`/opt/maca`是什么、为什么不能拿它编译"，`mccl-build-pitfalls.md`第1条就讲不成。规则是`mccl-remote-ops.md:5`和`mccl-build-pitfalls.md:5`各自声明的那条：**agent实际要执行的路径一律走`$MCCL_*`变量，字面路径只能出现在解释性文字里**。这比"不含真实文件系统路径"要宽，以这两份文档自己的声明为准。
