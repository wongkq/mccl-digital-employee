# 环境查找排队与定时任务（子系统⑥⑦）设计

日期：2026-07-31
状态：已确认，待实现
所属：MCCL数字员工平台 7 子系统之三（⑥ 环境查找排队 + ⑦ 定时任务）。本 spec 合并⑥⑦，因为两者共用同一队列与调度器。子系统①（GPU环境探测）②⑤（测试矩阵+前后对比）已完成并合并 main。

## 1. 背景与目标

现有 `/mccl-bench`（②⑤）和 `/mccl-run`（①）都是"立即跑"：用户发起即铺到 MCCL_NODES 上。两个痛点：

- **⑥**：GPU 繁忙时测试直接失败，靠人盯 GPU 是否空闲。需要"提交任务排队、自动探测环境、空闲再跑"。
- **⑦**：想夜间 GPU 空闲时自动跑预设场景，并实时看进度/暂停/终止。需要定时触发 + 任务状态机。

本子系统新增一个无状态调度器（cron 触发）+ 控制命令，把"提交-排队-探测-执行-控制"串起来。复用①的 `mccl-gpu-probe`（探测）、②⑤的 `/mccl-bench`（实际测试）。

### 平台位置

7 子系统里⑥⑦在①②⑤之后：依赖①的 `gpu-verdict.json` 契约（READY/NOT_READY/error）做环境探测，依赖②⑤的 `/mccl-bench` 做实际测试。③（skill同步）、④（影响驱动验证）与本子系统正交。

## 2. 范围边界

**做：**
- 新增 `bin/mccl-queue-scheduler`（cron 触发的无状态调度器）：读队列、探测 MCCL_NODES、READY 则交 /mccl-bench 跑、NOT_READY 等下轮、检查 stop/pause 标志
- 新增 `commands/mccl-bench-queue.md`：submit/status/pause/stop/resume/list 子命令，读写队列状态文件
- 单一队列两入口：`/mccl-bench-queue submit`（⑥排队）+ CronCreate 定时 submit（⑦夜间）
- 实时控制：status 看进度、pause/stop/resume 写标志文件、调度器下轮询/下场景前检查
- 固定 5 分钟 cron 轮询

**不做（YAGNI）：**
- 不做常驻 daemon（范式 A：cron 调 CLI、状态全落盘、无 daemon）
- 不做机器池配置（复用 MCCL_NODES，不新增配置）
- 不做多任务并行（串行消费排头任务，避免争 GPU）
- 不做秒级 stop 响应（"下个场景单元格前"或"scheduler 轮询子进程"级，分钟级可接受）
- 不做④（影响驱动验证）、③（skill同步）

## 3. 核心约束

### 3.1 范式 A：cron 调 CLI、无 daemon、状态全落盘

调度器是确定性 bash 脚本，cron 每 5 分钟触发一次，单次执行跑完即退。所有状态在 `.mccl-bench-queue/queue.json`。scheduler 崩了下一轮 cron 重新读 queue.json 继续--无状态、崩溃可恢复。不用 daemon（生命周期管理复杂、与现有无状态子代理哲学冲突）。

### 3.2 单一队列两入口

`/mccl-bench-queue submit <任务>` 提交排队任务（⑥）。CronCreate 定时触发 `/mccl-bench-queue submit <夜间预设场景>`（⑦）。两者都进同一 queue.json，同一调度器消费。⑦ 不另建调度逻辑。

### 3.3 复用 MCCL_NODES，不新增机器池

req⑥"给定的机器列表"= `mccl-env.json` 的 `MCCL_NODES`。调度器对 MCCL_NODES 跑 prober，READY 才跑。不新增机器池配置文件（沿用 mccl-env 从 bash 收敛成单一 JSON 的哲学）。

### 3.4 控制接口 = CLI 子命令读写状态文件

`/mccl-bench-queue status|pause|stop|resume` 读写 `.mccl-bench-queue/` 下的状态文件（queue.json / pause.flag / stop-<task_id>.flag）。纯文件 IPC，无 daemon、无 socket。

### 3.5 stop 实时性 = 分钟级（下个场景前）

stop flag 在"scheduler 轮询 /mccl-bench 子进程时"或"下个场景单元格前"生效。场景是分钟级 mpirun，分钟级 stop 响应可接受。需秒级响应要 daemon（范式 B，已弃）。

### 3.6 固定 5 分钟轮询

cron 每 5 分钟触发 scheduler。GPU 释放不需要秒级响应，5 分钟延迟可接受。

### 3.7 scheduler 是确定性脚本，不 AI 推理状态机

调度逻辑（读队列、找排头、改状态、检查标志）是确定性 bash，不让 AI 推理。AI 只在 /mccl-bench 内部（planner 推断场景）出现。

## 4. 组件

### 4.1 `bin/mccl-queue-scheduler`（调度器，cron 触发）

**触发**：cron 每 5 分钟调 `bash bin/mccl-queue-scheduler`（无参数；状态全从 `.mccl-bench-queue/` 读）。

**每次触发做的事**（确定性，无 AI 推理）：
1. `flock /tmp/mccl-queue-scheduler.lock`（拿不到锁说明上轮还没跑完，直接退出，防重叠）
2. `cd REPO_ROOT; eval mccl-env-load.py`
3. 读 `.mccl-bench-queue/queue.json`（不存在则空队列，退出）
4. 全局控制：`[ -f pause.flag ]` -> scheduler.log 写"全局暂停，跳过"，退出
5. 找排头 PENDING 任务（queue.json 第一个 status=PENDING）：
   - `[ -f stop-<task_id>.flag ]` -> 改 status=STOPPED，删 stop flag，写回 queue.json，日志，退出
   - 无 PENDING 任务 -> 退出（队列空/全完成）
6. 探测环境：`bin/mccl-gpu-probe --mode full --reuse-bw .mccl-bench-queue/.bw-cache --out probe-<ts>.json`
   - 读 verdict 字段：
     - READY -> 步骤7
     - NOT_READY -> scheduler.log 写"task <id> 等待环境: <failures[]>"，退出（下轮再试）
     - error -> scheduler.log 写"task <id> 探测出错: <failures[]>"，退出（下轮再试，不轻易判 FAILED）
7. 改 task status=RUNNING，写回 queue.json
   - 后台调 `/mccl-bench <task.params>`，记子进程 PID
   - scheduler 轮询子进程状态 + stop flag：
     - stop-<task_id>.flag 命中 -> SIGTERM 子进程，status=STOPPED
     - 子进程自然退出 -> 读 run_dir 下 verdict-bench.md：PASS->DONE，REWORK/ABORT->FAILED
8. 更新 task: progress/rounds_done/run_dir/status，写回 queue.json，scheduler.log 记录

**stop 方案 (b)**：scheduler 持有 /mccl-bench 子进程 PID，自己轮询 stop flag，命中则 SIGTERM 优雅停。runner 不需知道 task_id（解耦）。SIGTERM 杀 mpirun 子进程树要小心（safety 第3条禁重启节点，不禁止 kill 自己起的测试进程）。

**probe error 退避**：prober 连续 12 轮（1小时）error 才判 FAILED + 告警。临时网络抖动不轻易判死。

### 4.2 `commands/mccl-bench-queue.md`（控制命令）

子命令（读写 `.mccl-bench-queue/` 状态文件）：
- `submit <任务描述> [--rounds N] [--compare]`：创建任务入队（status=PENDING），写 queue.json，返回 task_id
- `status [task_id]`：读 queue.json，显示队列（每个任务的 id/status/提交时间/进度/轮次）
- `pause`：写 `pause.flag`（全局暂停，调度器下轮看到就停）
- `stop <task_id>`：写 `stop-<task_id>.flag`（该任务下个检查点终止）
- `resume`：删 `pause.flag`（恢复调度）
- `list`：同 status 但只列任务 id+status

### 4.3 CronCreate（⑦ 的定时入口）

⑦ 的"夜间定时跑预设场景"= CronCreate 注册一个定时 prompt，到点触发 `/mccl-bench-queue submit <预设场景> --rounds N`。提交后进同一队列，调度器 5 分钟轮询消费。⑦ 不另建调度逻辑。

## 5. 数据流

```
入口1: /mccl-bench-queue submit <任务> --rounds 3 --compare
入口2: CronCreate 定时 -> /mccl-bench-queue submit <夜间预设场景>
  都写 -> .mccl-bench-queue/queue.json (status=PENDING)

cron 每5分钟 -> bin/mccl-queue-scheduler
  flock 加锁
  读 queue.json + 控制标志
  pause.flag? -> 日志退出
  stop-<id>.flag? -> 标 STOPPED 退出
  排头 PENDING 任务:
    mccl-gpu-probe --mode full -> probe-<ts>.json
    READY     -> status=RUNNING, 后台 /mccl-bench <params>, 轮询stop+子进程
    NOT_READY -> 日志"等待环境", 退出(下轮再试)
    error     -> 日志"探测出错", 退出(下轮再试; 连续12轮才FAILED)
  跑完 -> status=DONE/STOPPED/FAILED, 写回 queue.json

控制: /mccl-bench-queue status|pause|stop <id>|resume -> 读写状态文件
```

## 6. 状态文件布局

`.mccl-bench-queue/`（gitignore）：
```
.mccl-bench-queue/
├── queue.json              # 队列：[{task_id, desc, params, status, submitted_at, progress, rounds_done, run_dir}, ...]
├── pause.flag              # 仅 pause 时存在
├── stop-<task_id>.flag     # 仅 stop 某任务时存在
├── scheduler.log           # 调度器每次触发的日志（时间/动作/verdict）
├── probe-<ts>.json         # 最近一次 prober 探测结果
└── .bw-cache/              # prober 带宽缓存（跨任务复用）
```

**queue.json schema**：
```json
{"tasks":[
  {"task_id":"bench-20260731-001","desc":"测对称内存改动","params":"--rounds 3 --compare",
   "status":"PENDING|RUNNING|STOPPED|DONE|FAILED",
   "submitted_at":"2026-07-31T22:00:00","progress":"0/6 scenarios","rounds_done":0,
   "run_dir":".mccl-bench/2026-07-31-2200"}
]}
```
task status 五态（无 PAUSED--暂停是全局 pause.flag，不改变 task 状态）。

## 7. 错误处理

| 情况 | 动作 | 理由 |
|---|---|---|
| flock 拿不到锁 | 退出 | 上轮还在跑（/mccl-bench 长任务），不重叠 |
| queue.json 不存在/损坏 | 退出，日志 | 空队列或状态损坏，不擅自重建 |
| pause.flag 存在 | 跳过本轮 | 全局暂停 |
| stop-<id>.flag 命中排头 | 标 STOPPED，删 flag | 用户终止该任务 |
| prober NOT_READY | 退出等下轮 | GPU 忙，5分钟后重试 |
| prober error | 退出等下轮 | 探测出错不轻易判 FAILED（可能临时网络抖动） |
| prober 连续 12 轮 error | 标 FAILED + 告警 | 持续探测失败说明真有问题（12轮=1小时） |
| /mccl-bench REWORK/ABORT | status=FAILED | 测试本身失败 |
| /mccl-bench 被 stop | status=STOPPED | 用户中途终止 |
| scheduler 自身崩 | 下轮 cron 重新触发 | 无状态，崩溃不丢队列（queue.json 持久） |

**关键：scheduler 无状态、崩溃可恢复**。所有状态在 queue.json，scheduler 崩了下一轮 cron 重新读 queue.json 继续。

## 8. 测试策略

延续静态不变式 + 负向测试。`tests/check.sh` 加不变式：

- **21**：`bin/mccl-queue-scheduler` 存在、可执行、`--help` 退出码 0。
- **22**：`commands/mccl-bench-queue.md` 存在且正文含 `submit`/`status`/`pause`/`stop`/`resume` 子命令名。
- **23**：queue.json schema 静态校验--scheduler/queue 命令引用的字段名（task_id/status/params/progress）在 schema 定义处闭环。

**纯函数单测**：`bin/mccl-queue-scheduler` 的队列读写逻辑（读 queue.json、找排头 PENDING、改状态写回）是确定性纯函数，可单测。新增 `tests/test-queue.sh`：喂 mock queue.json，验"找排头""stop 标志命中""pause 跳过"等逻辑。远程探测/实际 /mccl-bench 调用无法本地验证（沿用诚实边界）。

每条不变式配负向测试。

**诚实边界**：scheduler 的 cron 触发、flock、/mccl-bench 子进程管理、stop 信号处理无法本地端到端验证。能验的：队列读写纯函数、静态不变式、schema 闭环。首用建议人工盯一轮。

## 9. Known Limitations（待决项，不阻塞实现）

1. **stop 实时性是分钟级**：stop flag 在"scheduler 轮询子进程"或"下个场景单元格前"生效，不是秒级。场景是分钟级 mpirun，可接受。需秒级响应要 daemon（范式 B，已弃）。
2. **CronCreate 7天自动过期**：⑦ 的夜间定时用 CronCreate 注册，recurring 任务 7 天后自动过期（harness 限制）。需定期重注册，或改用系统 cron（`crontab -e`）做持久定时。spec 标注此限制。
3. **单任务串行**：调度器一次只跑排头一个任务（flock + 串行消费）。不支持多任务并行（多任务会争 GPU）。符合"避免 GPU 繁忙导致失败"的初衷。
4. **probe 带宽缓存跨任务复用**：scheduler 的 `.bw-cache/` 跨任务复用（同 MCCL_NODES 环境不变），沿用①的缓存思路。但占用每轮重查（①已设计，环境在 run 内不变但跨任务可能变）。
5. **scheduler 不代 prober 做"找空闲主机"**：⑥ 的"自动查找可用 GPU"= 对 MCCL_NODES 跑 prober，READY 才跑。不是"从大池子里挑一台空闲的"（机器池方案已弃，复用 MCCL_NODES）。
6. **远程行为未经端到端验证**：scheduler 的 cron 触发、flock、/mccl-bench 子进程管理、stop 信号处理无法本地端到端验证，首用建议人工盯一轮。

## 10. 实现件清单

| 件 | 路径 | 动作 |
|---|---|---|
| 调度器脚本 | `plugins/.../bin/mccl-queue-scheduler` | 新增（bash，可执行） |
| 控制命令 | `plugins/.../commands/mccl-bench-queue.md` | 新增 |
| 队列单测 | `plugins/.../tests/test-queue.sh` | 新增（纯函数单测） |
| 自检 | `plugins/.../tests/check.sh` | 加不变式21/22/23 + 负向测试 |
| 文档 | `README.md` | 追加"环境排队与定时任务"小节 |
| safety | `references/mccl-safety.md` | 追加"scheduler stop 只 kill 自己起的测试进程，不杀无关进程/不重启节点" |

## 11. 不做的事（YAGNI 边界）

- 不做常驻 daemon（范式 A：cron 调 CLI、无 daemon）
- 不做机器池配置（复用 MCCL_NODES）
- 不做多任务并行（串行消费）
- 不做秒级 stop 响应（分钟级可接受）
- 不做④③（正交子系统）
