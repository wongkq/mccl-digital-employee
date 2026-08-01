# skill 同步（子系统③）设计文件

**日期**：2026-08-01
**状态**：已确认，待实现
**所属**：MCCL数字员工平台 7 子系统之四（③ skill 坑/场景/模板经验同步）。
其余六条：①（GPU探测）②⑤（测试矩阵+性能报告）⑥⑦（环境排队+定时任务）已完成并合并 main。

## 1. 背景与目标

这个仓库既是**安装载体**（用户装你的代理），也是**知识库**（你在里面记录的坑/场景/应答模板）。但两者之间缺一条**经验同步链**：你在这个仓库里写完坑、加好场景、下发答案、打表情——这些**改动**统统在本地这份仓库状态里，其他仓库里的人看不到。

典型缺口：

- 你在仓库 A 把 `references/mccl-build-pitfalls.md`实际上写满了一个坑：在仓库B 的 jammer 根本就无法拿到这份经验
- 你把 `references/mccl-domain.md`上加了一个测试场景：到仓库 B 的人也看不到
- 你判完了 ABORT/REWORK 这个 verdict：仓库 B 的人吃不到

③ 要把这条链补上：让你的**经验更新、新加、变动**一键变 **commit+push**，让其他人 clone 下来就能装，分站节点的事故（maco 攘灶）/大公开（公开访问）也可以长期 Ed。

- **手工触发**：用户问你说「看一下 skill 有什么更新了」就 `/mccl-skill-sync`
- **周期触发**：CronCreate 定时（周期）挂到 `/mccl-skill-sync`，它 auto
- **联动建议**：`/mccl-bench` / `/mccl-bench-queue complete`/ /mccl-run 完成后，reporter/supervisor/reporter+supervisor 写一条 `pending`的 `pending.jsonl`（状态 `candidate`），③手动/周期打正一个 diff 档给"经验的更新"（"查看的"手动看看）
- **git 动作**：auto commit+push（check.sh 硬闸门，洁只可 commit+push）

## 2. 范围边界

**做：**
- 单一 agent：`plugins/.../agents/mccl-skill-sync.md`（③ skill 坑/场景/模板经验同步专员）
- 单一候选池：`~/.mccl-skill-sync/pending.jsonl`（JSONL 追加，落盘交互且跨仓库单独一份）
- 单一预看档：`~/.mccl-skill-sync/review/<候选id>.patch`（给用户看的 What + Why）
- 入口：
  - **手动**：`/mccl-skill-sync [候选标题]`
  - **自动**：CronCreate 定时（周期）
  - **联动建议**：`/mccl-bench`/`/mccl-bench-queue complete`/ run 完成时，reporter/supervisor/reporter+supervisor 写一条 `pending.jsonl`（状态 `candidate`）
- **git 动作**：auto commit+push（check.sh 硬闸门，洁才可 commit+push）
- **同步对象**：这个仓库的安装载体 + 这个仓库的知识档（不做行为规范、不做「 出文件喵」、不做「 指没在资源单」）

**不做（YAGNI）：**
- 不出 submodule / dependency（不变成某个包者变速）
- 不定分钟成永性奇怪（暂不做这批和hosts的 N 个链互斥白名单）
- 不动 `references/` mccl -mccl-domain.md`/`mccl-build-pitfalls.md`):references 是"答**"本身，不在自动化区动**；也到「 动 **答**」
- 不动`*.so/*.pyc/*.log`这类执行生产物
- 不做多仓库互斥白名单（暂不让这套给每台机器）

## 4. 核心约束

### 4.1 候选池是 JSONL 追加式

- `~/.mccl-skill-sync/pending.jsonl` 一直追加，每行一个对象:
```
{"id":"skill-20260801-001","title":"...","desc":"...","files":[...],
 "summary":"...","generated_at":"2026-08-01T10:00:00","source":"bench|queue|run|manual",
 "status":"pending|reviewed|approved|rejected","git_message":"...",
 "action":"approve|reject","approved_at":"...","approved_by":"..."}
```
- JSONL = 可追加 + 无并发 + 跨仓库单独一份。每仓库自己一份状态。
- 联动产出者只追加，不丢状态、不重写

### 4.2 联动产出只追加，不丢状态不重写

- `reporter/supervisor/reporter+supervisor` 结算时往 `pending.jsonl` 写：
- 若有联动建议，就追加一条 `status=pending` 的候选（`title=report-N|bench|run`、`desc=verdict 摘要`、`source=bench|run|queue`、`files=[变动摘要]`）
- 只是一次性追加（ append）：③ sync 代理打捞后走到 approved/rejected 的链：

### 4.3 Auto commit+push 是③ 所属 agent 专属

- `references/mccl-safety.md` 第4条更新：「③ skill 同步 auto commit+push 的 agent 可以调用 `git push`；其他 agent 禁用」
- 手工→ auto 是默认；用户安心看到 「我要停某个变动」= approve/reject 手动批量拦截
- **`mccl-skill-sync.md`** `git 降級 （PSA，不响应，常做` message'）不出问题

### 4.4 结算态有序，且只往前追加

- 每条候选：`pending → reviewed → approved → rejected`，用户改主意往后也能追加
- 第一条是不可停：用户改主意就往后「追加一条新状态」，不重写历史
- check.sh 是硬闸门：结算如果 check.sh 没跑过，**不动 git**

### 4.5 候选池是「更新」选：「不要照一张案传下去（bad practice）」

- 不同步 `*.so/*.pyc/*.log`这类执行产物（`白名单正常`）
- 不同步 `references/` mccl-mccl-domain.md`/`mccl-build-pitfalls.md` 等 mccl-references/` 的文件：references 是" **答** **"本身**

### 4.6 默认= auto

- **默认 = auto**：用户打 `/mccl-skill-sync` 不带参数，sync 代理默认按周期跑
- 手动看单个候选就是手动：`/mccl-skill-sync <候选标题>`
- 「是否修改某个变动」= approve/reject 整单

### 4.7Safety\section：maco.h:

### 4.7安全是硬闸门
- 每次结算前必经 `tests/check.sh`（`check.sh III-24/III-25`）
- check.sh 不 mod= 不 commit 不 push
- `/mccl-gitlab.yml`、财务报表：mccl-domain.md`/`mccl-build-pitfalls.md` 等不动

## 5. 组件

### 5.1 `agents/mccl-skill-sync.md`（③ skill 同步专员）

- 启动门槛：/mccl-skill-sync [候选标题]`，或 `/mccl-skill-sync`（默认自动挡）
- 开工：复核 `references/mccl-safety.md` 第4条（明确放开给③ agent push；其他 agent 禁用）+
- 4.3：4.5 中标
- 职责：
  - 把候选 `pending` 打捞，一条一条拉
  - 对每条候选：收动文件、action（动一条不会被复的 git commit+push 和 status=approved/rejected）、 `pending.jsonl` 追加状态
  - 手动：从 `review/` 档捞出 What+Why 给用户看，approve → approved（走 git push）、reject → rejected（状态记录不动 git）
  - 设 `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` 等 git commit author 环境变量（避免 commit author 变成一车祸）

### 5.2 本地候选池 `~/.mccl-skill-sync/pending.jsonl`

- 文件追加格式：每行一个对象（上§3.1 的 schema）
- 兼容多仓库共享：每仓库自己一份、单独一份状态
- `GHC_SSH_PASS`手工控制台：
- **不走 `~全局变量` / exports***：>: 每次 sync agent 运行时都要重新 source 当前 shell 的 ~/.zshrc / ~/.bashrc（`source ~/.bashrc` 或 `source ~/.profile`）

### 5.3 预看档 `~/.mccl-skill-sync/review/<候选id>.patch`

- 名字：单一 diff 档（git diff 输出）+ 头简短描述这次变动（What + Why）
- 用户先看到 approve、reject：>
  - approve → `approved`（走 git add & commit & push）
  - reject → `rejected`（状态记录不动 git）
- 只要被 approve 或 reject 后就不在 review/ 档里在 `pending.jsonl` 提示状态 `approved` 或 `rejected`

### 5.4 用户入口 `/mccl-skill-sync`

- 命令档：`commands/mccl-skill-sync.md`
- 手动筛选候选：
  - `/mccl-skill-sync` 无参数：>sync 代理按周期跑，一条一条拉候选打捞
  - `/mccl-skill-sync <候选标题>`：>sync 代理指定某条手动筛选
- 用户对 「是否修改 某个变动」：>/mccl-skill-sync review |/mccl-skill-sync <候选标题>` 把候选听成 user's way，把 「这次的更新」变成 user 的"手动式召唤"

## 数据流

```
来源（手动/CronCreate 周期/联动建议）
  ↓
~/.mccl-skill-sync/pending.jsonl（状态=pending）
  ↓
sync 代理打捞
  ├─ 手动 → 从 review/<id>.patch 得出 What+Why → approve/reject
  └─ 自动 → reject-all-default / accept-all-default
  ↓
approved → git add & commit & push（check.sh 硬闸关卡）
rejected → 状态记录不动 git
  ↓
状态追加回 pending.jsonl
```

## 7. 错误处理

| 情况 | 动作 | 理由 |
|---|---|---|
| check.sh 未跑过/蛛 | **不动 git**，状态警告 | 硬闸门：结算失败= barrier |
| git 网络断/rpc 超时 | 不动 git 状态 | 用户改主意就能停的可靠 |
| 候选重复 | 状态继续追加 | 多轮的候选（候选池不丢，不丢） |
| sync 代理自身崩 | gitpush 继续跑 | 候选不丢（候选池已落盘） |

## 8. 测试策略

### 8.1 静态不变式（check.sh 续）

- III-24：`agents/mccl-skill-sync.md` 存在（**具git add/commit/push** 调用约定）
- III-25：`commands/mccl-skill-sync.md` 存在（**含 `GIT_SSH_PASS` 字符串）（密码需被 notice）**

### 8.2 联动产出 reliable（reporter+supervisor）

- reporter+supervisor 结算时往 `pending.jsonl` 写：
- **联动建议单测**：>替身 reporter+supervisor 结算时产出候选，sync 代理要跑一次要打捞

### 6.3 负向测试

- **联动建议产出 fake**：一场代理伪造 pending.jsonl 中带 `source=bench` 的候选，sync 代理要拒绝
- **私有档**：>- 撞check.sh：>/mccl-gitlab.yml`、`mccl-domain.md`/`mccl-build-pitfalls.md` 被 sync 代理 modify 时立即清扫

### 6.4 批评边界

- 能验的：>候选池 JSONL 结构、联动产出者候选结构、static check.sh 静态保证
- **不能验的**：>被sync 代理一次性捞回后 git push 打通的真实仓库链路、CronCreate 定时运行的时序、被 approve/reject 的最后处理。首次上线人重复。

## 9. Known Limitations（待决项，不阻塞实现）

1. **③ agent 可以改 safety 第4条**（① probe 第9条+（6） scheduler）只有它允许 git push，其他 agent 禁用
2. **CronCreate automatic 7 天自动过期**（⑦ 同样硬伤）——需定期重注册或改 system cron（`crontab -e`）
3. **联动产出者是只追加的**——reporter/supervisor 产生 `pending` 后，他们要锈OK保持可lime的，可继续追加流程
4. **不动 `references/`**：:references 是"答"本身，不在自动化区动
5. **推 git 无手动确认**：`/mccl-skill-sync` 带 auto adoptions（`GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`）Sync 代理出 contemplate finish如果 git 不动
- MCCL域「打表等待」是另类争议（`mccl-gitlab.yml` 或 `~/.mccl-skill-sync` 是 `:` 索引相同 但 fake 关键档）——>尝试：自动识别（`auto sync`、`mccl-gitlab.yml` 是内容相关：）

##10. 实现件清单

| 件 | 路径 | 动作 |
|---|---|---|
| skill 同步专员 agent | `plugins/.../agents/mccl-skill-sync.md` | 新增 |
| 手动入口 | `plugins/.../commands/mccl-skill-sync.md` | 新增 |
| `references/mccl-safety.md` | 第4条更新：gap 是（① probe第9条 +（6） scheduler）只放开给③ agent push；其他 agent 禁用 |
| `plugins/.../tests/check.sh` | 加 ③ 专属规则（III-24/III-25） |
| 联动产出：reporter/supervisor/reporter+supervisor | reporter+supervisor 结算时产生候选 |
| README | 追加 `skill 同步（③）` 小节  |

## 11. 不做的事（YAGNI 边界）

- 不出 submodule / 跨仓库的 distribute
- 不定分钟级同步（ speed=秒级）
- 不动 `references/` ： references 是**"答**"本身，不在自动化区动
- 不做多仓库互斥白名单（暂不做这些都的N 个链互斥白名单）
