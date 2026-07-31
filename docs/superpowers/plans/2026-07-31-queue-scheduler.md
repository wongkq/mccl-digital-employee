# 环境查找排队与定时任务（子系统⑥⑦）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 cron 触发的无状态队列调度器 `bin/mccl-queue-scheduler` + 控制命令 `/mccl-bench-queue`，实现任务排队、自动探测环境、空闲再跑、暂停/终止控制。

**Architecture:** 范式 A：`bin/mccl-queue-scheduler`（bash，纯函数可单测 + 调度循环）被 cron 每 5 分钟触发，读 `.mccl-bench-queue/queue.json`、对排头任务调①`mccl-gpu-probe` 探测、READY 则输出 `DISPATCH:<task_id>:<params>` 交 Claude 跑②⑤`/mccl-bench`、NOT_READY 等下轮、检查 stop/pause 标志。控制子命令（submit/status/pause/stop/resume/complete）读写状态文件。bash 不调 Claude 命令（调不了），DISPATCH 输出由 CronCreate 触发的 Claude 会话消费。

**Tech Stack:** Bash（调度器，纯函数源码可测 + flock + 信号）、Python3（JSON 安全读写）、Markdown（命令/参考）、Claude Code 的 commands 机制 + CronCreate。

## Global Constraints

以下约束适用于每个任务，值从 spec 逐字抄录：

- **范式 A：cron 调 CLI、无 daemon、状态全落盘。** 调度器是确定性 bash 脚本，单次执行跑完即退。所有状态在 `.mccl-bench-queue/queue.json`。崩溃下轮 cron 恢复。不用 daemon。
- **scheduler 是确定性脚本，不 AI 推理状态机。** 调度逻辑（读队列、找排头、改状态、检查标志）是确定性 bash。AI 只在 /mccl-bench 内部（planner 推断场景）出现。
- **单一队列两入口。** `/mccl-bench-queue submit`（⑥排队）+ CronCreate 定时 submit（⑦夜间）进同一 queue.json，同一调度器消费。
- **复用 MCCL_NODES，不新增机器池。** 调度器对 MCCL_NODES 跑 prober，READY 才跑。
- **控制接口 = CLI 子命令读写状态文件。** submit/status/pause/stop/resume/complete 读写 `.mccl-bench-queue/` 下文件。纯文件 IPC，无 daemon、无 socket。
- **stop 实时性 = 分钟级。** v1 在 /mccl-bench 完成后检查 stop flag（不中途杀场景）；下个场景间 stop 留后续。
- **固定 5 分钟轮询。** cron 每 5 分钟触发。
- **prober 连续 12 轮（1小时）error 才判 FAILED。** 临时网络抖动不轻易判死。
- **所有 ssh/scp 必须带 `$MCCL_SSH_OPTS`**（裸 ssh 卡死）。check.sh 不变式13 扫新 bin/。
- **远程行为无法端到端验证。** scheduler 的 cron 触发、flock、prober 调用、/mccl-bench 派发无法本地验证。能验的：队列读写纯函数、控制子命令、静态不变式。
- **queue.json schema 契约**（跨任务）：
  ```json
  {"tasks":[{"task_id":"bench-20260731-001","desc":"...","params":"--rounds 3 --compare",
   "status":"PENDING|RUNNING|STOPPED|DONE|FAILED",
   "submitted_at":"","progress":"","rounds_done":0,"run_dir":"","probe_errors":0}]}
  ```
  task status 五态（无 PAUSED--暂停是全局 pause.flag）。`probe_errors` 记录连续探测出错次数，>=12 判 FAILED。
- **scheduler 输出契约**（调度循环 stdout，供 CronCreate 触发的 Claude 会话消费）：
  - `DISPATCH:<task_id>:<params>` — READY，Claude 应跑 /mccl-bench
  - `WAIT:<task_id>:<reason>` — NOT_READY/error，等下轮
  - `STOP:<task_id>` — stop flag 命中，已标 STOPPED
  - `SKIP:<reason>` — 暂停/空队列/锁占用，无事可做

---

## File Structure

```
plugins/mccl-digital-employee/
├── bin/
│   └── mccl-queue-scheduler          # 新增：调度器+控制子命令（bash，纯函数可单测）
├── commands/
│   └── mccl-bench-queue.md           # 新增：控制命令（thin dispatcher 调 bin/）
├── references/
│   └── mccl-safety.md                # 改：追加第10条（scheduler stop 只 kill 自己起的进程）
└── tests/
    ├── check.sh                      # 改：加不变式21/22/23 + 负向测试
    └── test-queue.sh                 # 新增：队列纯函数+控制子命令单测
README.md                             # 改：追加"环境排队与定时任务"小节（含 CronCreate 设置）
```

## Interfaces（跨任务契约）

**agent/命令名**（Task 2 定义，Task 3 校验）：`mccl-bench-queue`（命令）。
**调度器路径**（Task 1 产出，Task 2/3 引用）：`bin/mccl-queue-scheduler`。
**queue.json schema**（Task 1 产出，Task 2/3 消费）：见 Global Constraints。
**scheduler 输出契约**（Task 1 产出，README 的 CronCreate 提示消费）：见 Global Constraints。
**状态文件布局**：`.mccl-bench-queue/{queue.json, pause.flag, stop-<task_id>.flag, scheduler.log, probe-<ts>.json, .bw-cache/}`。

---

### Task 1: bin/mccl-queue-scheduler 调度器 + 队列单测

**Files:**
- Create: `plugins/mccl-digital-employee/bin/mccl-queue-scheduler`
- Create: `plugins/mccl-digital-employee/tests/test-queue.sh`

**Interfaces:**
- Consumes: `bin/mccl-gpu-probe`（①，探测）、`mccl-env.json`（MCCL_NODES）、`bin/mccl-env-load.py`
- Produces: `bin/mccl-queue-scheduler`（可执行）；纯函数 `queue_head_pending_id`/`queue_set_status`/`queue_set_field`/`add_task`/`has_pause_flag`/`has_stop_flag`（被 test-queue.sh source 单测）；控制子命令 `submit/status/pause/stop/resume/list/complete`；调度循环输出契约（DISPATCH/WAIT/STOP/SKIP）；queue.json schema

- [ ] **Step 1: 写纯函数 + 控制子命令单测（TDD，先写测试）**

Create `plugins/mccl-digital-employee/tests/test-queue.sh`:

```bash
#!/usr/bin/env bash
# tests/test-queue.sh - bin/mccl-queue-scheduler 队列纯函数与控制子命令的本地验证。
# 调度循环（flock/prober/派发）无法本地验证，见 spec §8 诚实边界。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
SCHED="$PLUGIN_ROOT/bin/mccl-queue-scheduler"

pass=0; fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok:   $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}
[ -f "$SCHED" ] || { echo "FAIL: $SCHED 不存在" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SCHED" 2>/dev/null || { echo "FAIL: 无法 source $SCHED" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. add_task + queue_head_pending_id ---
echo '{"tasks":[]}' > "$TMP/queue.json"
add_task "$TMP/queue.json" "t1" "测对称" "--rounds 3 --compare"
add_task "$TMP/queue.json" "t2" "测非对称" "--rounds 1"
assert_eq "head pending t1" "t1" "$(queue_head_pending_id "$TMP/queue.json")"

# --- 2. queue_set_status 后 head 移到下一个 ---
queue_set_status "$TMP/queue.json" "t1" "DONE"
assert_eq "head pending t2 after t1 done" "t2" "$(queue_head_pending_id "$TMP/queue.json")"

# --- 3. queue_set_field ---
queue_set_field "$TMP/queue.json" "t2" "progress" "3/6"
progress=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][1]["progress"])' "$TMP/queue.json")
assert_eq "set field progress" "3/6" "$progress"

# --- 4. has_pause_flag / has_stop_flag ---
mkdir -p "$TMP/qd"
assert_eq "no pause flag" "1" "$(has_pause_flag "$TMP/qd"; echo $?)"
touch "$TMP/qd/pause.flag"
assert_eq "has pause flag" "0" "$(has_pause_flag "$TMP/qd"; echo $?)"
assert_eq "no stop flag" "1" "$(has_stop_flag "$TMP/qd" "t1"; echo $?)"
touch "$TMP/qd/stop-t1.flag"
assert_eq "has stop flag" "0" "$(has_stop_flag "$TMP/qd" "t1"; echo $?)"

# --- 5. 空队列/无PENDING/文件缺失 ---
echo '{"tasks":[]}' > "$TMP/empty.json"
assert_eq "empty queue head" "" "$(queue_head_pending_id "$TMP/empty.json")"
echo '{"tasks":[{"task_id":"x","status":"DONE","desc":"","params":""}]}' > "$TMP/nopend.json"
assert_eq "no pending head" "" "$(queue_head_pending_id "$TMP/nopend.json")"
assert_eq "missing file head" "" "$(queue_head_pending_id "$TMP/missing.json")"

# --- 6. cmd_submit（控制子命令）---
QUEUE_DIR="$TMP/qd2" cmd_submit "夜间对称测试" --rounds 5 --compare >/dev/null 2>&1
assert_eq "submit created queue.json" "1" "$(test -f "$TMP/qd2/queue.json" && echo 1 || echo 0)"
assert_eq "submit task PENDING" "PENDING" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["status"])' "$TMP/qd2/queue.json")"
assert_eq "submit params recorded" "--rounds 5 --compare" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["params"])' "$TMP/qd2/queue.json")"

# --- 7. cmd_pause / cmd_resume / cmd_stop ---
QUEUE_DIR="$TMP/qd2" cmd_pause >/dev/null 2>&1
assert_eq "pause flag exists" "0" "$(has_pause_flag "$TMP/qd2"; echo $?)"
QUEUE_DIR="$TMP/qd2" cmd_resume >/dev/null 2>&1
assert_eq "pause flag gone" "1" "$(has_pause_flag "$TMP/qd2"; echo $?)"
QUEUE_DIR="$TMP/qd2" cmd_stop "bench-xxx" >/dev/null 2>&1
assert_eq "stop flag exists" "0" "$(has_stop_flag "$TMP/qd2" "bench-xxx"; echo $?)"

# --- 8. cmd_complete ---
QUEUE_DIR="$TMP/qd2" cmd_complete "bench-xxx" "DONE" >/dev/null 2>&1
# bench-xxx 不在队列（submit 创建的是另一个 id），所以 complete 不改任何任务--验不崩即可
tid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["task_id"])' "$TMP/qd2/queue.json")
QUEUE_DIR="$TMP/qd2" cmd_complete "$tid" "DONE" >/dev/null 2>&1
st=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["status"])' "$TMP/qd2/queue.json")
assert_eq "complete sets DONE" "DONE" "$st"

echo
[ "$fail" -eq 0 ] && echo "queue 测试全部通过 ($pass)" || echo "queue 测试有失败 ($fail)"
exit "$fail"
```

- [ ] **Step 2: 跑测试，确认失败（脚本不存在）**

Run: `bash plugins/mccl-digital-employee/tests/test-queue.sh`
Expected: `FAIL: .../bin/mccl-queue-scheduler 不存在`，退出码 1。

- [ ] **Step 3: 创建 bin/mccl-queue-scheduler（完整脚本）**

Create `plugins/mccl-digital-employee/bin/mccl-queue-scheduler`:

```bash
#!/usr/bin/env bash
# bin/mccl-queue-scheduler - MCCL bench 队列调度器（子系统⑥⑦）
#
# 范式A：cron每5分钟触发（无参数=调度循环），或控制子命令。
# 无状态：所有状态在 .mccl-bench-queue/queue.json，崩溃下轮cron恢复。
# 不用daemon。调度逻辑确定性，不AI推理。
#
# 退出码：0=正常（无论是否DISPATCH），2=脚本自身出错。
#
# 纯函数（queue_*）可被 tests/ 源码加载单测；schedule_loop 才做远程编排。
set -uo pipefail

# ===================== 纯函数（可单测，不碰远程/环境） =====================

# queue_head_pending_id <queue.json> - 打印第一个 PENDING 任务的 task_id（无则空）
queue_head_pending_id() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return 1; }
  python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except: print(""); sys.exit(0)
for t in d.get("tasks",[]):
    if t.get("status")=="PENDING":
        print(t.get("task_id","")); sys.exit(0)
print("")
' "$f"
}

# queue_set_status <queue.json> <task_id> <new_status>
queue_set_status() {
  python3 -c '
import json,sys
f,tid,st=sys.argv[1],sys.argv[2],sys.argv[3]
try: d=json.load(open(f))
except: d={"tasks":[]}
for t in d.get("tasks",[]):
    if t.get("task_id")==tid: t["status"]=st
json.dump(d,open(f,"w"),ensure_ascii=False,indent=2)
' "$1" "$2" "$3"
}

# queue_set_field <queue.json> <task_id> <field> <value>
queue_set_field() {
  python3 -c '
import json,sys
f,tid,fld,val=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
try: d=json.load(open(f))
except: d={"tasks":[]}
for t in d.get("tasks",[]):
    if t.get("task_id")==tid: t[fld]=val
json.dump(d,open(f,"w"),ensure_ascii=False,indent=2)
' "$1" "$2" "$3" "$4"
}

# add_task <queue.json> <task_id> <desc> <params>
add_task() {
  python3 -c '
import json,sys
f,tid,desc,prms=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
try: d=json.load(open(f))
except: d={"tasks":[]}
d["tasks"].append({"task_id":tid,"desc":desc,"params":prms,"status":"PENDING",
    "submitted_at":"","progress":"","rounds_done":0,"run_dir":"","probe_errors":0})
json.dump(d,open(f,"w"),ensure_ascii=False,indent=2)
' "$1" "$2" "$3" "$4"
}

# has_pause_flag <dir> - return 0 if pause.flag exists
has_pause_flag() { [ -f "$1/pause.flag" ]; }

# has_stop_flag <dir> <task_id> - return 0 if stop-<task_id>.flag exists
has_stop_flag() { [ -f "$1/stop-$2.flag" ]; }

# ===================== 控制子命令 =====================

cmd_submit() {
  local desc="$1"; shift
  local params=""
  while [ $# -gt 0 ]; do params="$params $1"; shift; done
  params="${params# }"
  local tid="bench-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$QUEUE_DIR"
  [ -f "$QUEUE_DIR/queue.json" ] || echo '{"tasks":[]}' > "$QUEUE_DIR/queue.json"
  add_task "$QUEUE_DIR/queue.json" "$tid" "$desc" "$params"
  echo "提交任务: $tid"
  echo "参数: $params"
  echo "用 /mccl-bench-queue status 查看队列"
}

cmd_status() {
  [ -f "$QUEUE_DIR/queue.json" ] || { echo "队列为空（无 queue.json）"; return; }
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
if not d.get("tasks"): print("队列为空"); sys.exit(0)
print(f"{'task_id':<24} {'status':<10} {'progress':<16} {'desc'}")
for t in d["tasks"]:
    print(f"{t[\"task_id\"]:<24} {t[\"status\"]:<10} {t.get(\"progress\",\"\"):<16} {t[\"desc\"]}")
' "$QUEUE_DIR/queue.json"
}

cmd_pause() { mkdir -p "$QUEUE_DIR"; touch "$QUEUE_DIR/pause.flag"; echo "已暂停（写 pause.flag，调度器下轮跳过）"; }
cmd_resume() { rm -f "$QUEUE_DIR/pause.flag"; echo "已恢复（删 pause.flag）"; }
cmd_stop() {
  local tid="$1"
  mkdir -p "$QUEUE_DIR"
  touch "$QUEUE_DIR/stop-$tid.flag"
  echo "已请求终止 $tid（写 stop flag，/mccl-bench 完成后生效）"
}
cmd_list() { cmd_status; }

# cmd_complete <task_id> <status> - /mccl-bench 跑完后由 Claude 调用
cmd_complete() {
  local tid="$1" st="$2"
  [ -f "$QUEUE_DIR/queue.json" ] || { echo "queue.json 不存在"; return 1; }
  queue_set_status "$QUEUE_DIR/queue.json" "$tid" "$st"
  echo "任务 $tid 标记为 $st"
}

usage() {
  cat <<'EOF'
用法: mccl-queue-scheduler [子命令]
无参数 = 调度循环（cron 每5分钟触发，输出 DISPATCH/WAIT/STOP/SKIP）。
控制子命令:
  submit <描述> [--rounds N] [--compare]  提交任务入队
  status [task_id]                        显示队列状态
  pause                                   全局暂停
  stop <task_id>                          终止指定任务
  resume                                  恢复调度
  list                                    列出任务
  complete <task_id> <DONE|FAILED|STOPPED> /mccl-bench 跑完后标记
EOF
}

# ===================== 调度循环（无参数，cron 触发） =====================

schedule_loop() {
  local qd="$QUEUE_DIR"
  mkdir -p "$qd"
  local log="$qd/scheduler.log"

  # flock 防并发
  exec 9>"$qd/.scheduler.lock"
  flock -n 9 || { echo "$(date '+%F %T'): 上轮调度仍在运行，跳过" >> "$log"; echo "SKIP:lock"; return 0; }

  [ -f "$qd/queue.json" ] || { echo "$(date '+%F %T'): queue.json 不存在，空队列" >> "$log"; echo "SKIP:empty"; return 0; }

  # 全局暂停
  if has_pause_flag "$qd"; then
    echo "$(date '+%F %T'): 全局暂停，跳过" >> "$log"
    echo "SKIP:paused"; return 0
  fi

  # 找排头 PENDING
  local head
  head=$(queue_head_pending_id "$qd/queue.json")
  [ -n "$head" ] || { echo "$(date '+%F %T'): 无 PENDING 任务" >> "$log"; echo "SKIP:no-pending"; return 0; }

  # stop 标志检查
  if has_stop_flag "$qd" "$head"; then
    queue_set_status "$qd/queue.json" "$head" "STOPPED"
    rm -f "$qd/stop-$head.flag"
    echo "$(date '+%F %T'): 任务 $head 被 stop，标记 STOPPED" >> "$log"
    echo "STOP:$head"; return 0
  fi

  # 探测环境（调① mccl-gpu-probe）
  local probe_out="$qd/probe-$(date +%s).json"
  local probe_rc=0
  "$TOOLKIT_ROOT/bin/mccl-gpu-probe" --mode full --reuse-bw "$qd/.bw-cache" --out "$probe_out" 2>>"$log" || probe_rc=$?

  # 读 verdict（prober 退出码：0=READY 1=NOT_READY 2=error；但主控契约是读 JSON verdict 字段）
  local verdict
  verdict=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("verdict","error"))' "$probe_out" 2>/dev/null || echo "error")

  case "$verdict" in
    READY)
      # 重置 probe_errors，标 RUNNING，输出 DISPATCH
      queue_set_field "$qd/queue.json" "$head" "probe_errors" "0"
      queue_set_status "$qd/queue.json" "$head" "RUNNING"
      local params
      params=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for t in d.get("tasks",[]):
    if t.get("task_id")==sys.argv[2]: print(t.get("params","")); break
' "$qd/queue.json" "$head")
      echo "$(date '+%F %T'): 任务 $head READY，派发 /mccl-bench $params" >> "$log"
      echo "DISPATCH:$head:$params"
      ;;
    NOT_READY)
      echo "$(date '+%F %T'): 任务 $head 等待环境（NOT_READY）" >> "$log"
      echo "WAIT:$head:环境未就绪"
      ;;
    *)
      # error：累加 probe_errors，>=12 判 FAILED
      local errs
      errs=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for t in d.get("tasks",[]):
    if t.get("task_id")==sys.argv[2]:
        e=t.get("probe_errors",0)+1; t["probe_errors"]=e; print(e); break
json.dump(d,open(sys.argv[1],"w"),ensure_ascii=False,indent=2)
' "$qd/queue.json" "$head" 2>/dev/null || echo "1")
      if [ "${errs:-0}" -ge 12 ] 2>/dev/null; then
        queue_set_status "$qd/queue.json" "$head" "FAILED"
        echo "$(date '+%F %T'): 任务 $head 连续 $errs 轮探测出错，标记 FAILED" >> "$log"
        echo "STOP:$head"
      else
        echo "$(date '+%F %T'): 任务 $head 探测出错（连续 $errs 轮），等下轮" >> "$log"
        echo "WAIT:$head:探测出错(连续${errs}轮)"
      fi
      ;;
  esac
}

# ===================== 环境与根解析 =====================

resolve_roots() {
  command -v python3 >/dev/null 2>&1 || { echo "mccl-queue-scheduler: 需要 python3" >&2; return 1; }
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "mccl-queue-scheduler: 不在 git 仓库内" >&2; return 1; }
  # TOOLKIT_ROOT 解析（同 mccl-toolkit-root 逻辑）
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/references/mccl-safety.md" ]; then
    TOOLKIT_ROOT="${CLAUDE_PLUGIN_ROOT}"
  else
    TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  [ -f "$TOOLKIT_ROOT/references/mccl-safety.md" ] || { echo "mccl-queue-scheduler: 找不到 references/" >&2; return 1; }
  eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")" || return 1
  QUEUE_DIR="$REPO_ROOT/.mccl-bench-queue"
}

# ===================== main =====================

main() {
  if [ $# -eq 0 ]; then
    resolve_roots || { echo "SKIP:env-error" >&2; exit 2; }
    schedule_loop
    exit 0
  fi
  case "$1" in
    submit) shift; resolve_roots || exit 2; cmd_submit "$@";;
    status) resolve_roots || exit 2; cmd_status;;
    pause) resolve_roots || exit 2; cmd_pause;;
    stop) resolve_roots || exit 2; cmd_stop "$2";;
    resume) resolve_roots || exit 2; cmd_resume;;
    list) resolve_roots || exit 2; cmd_list;;
    complete) resolve_roots || exit 2; cmd_complete "$2" "$3";;
    -h|--help) usage; exit 0;;
    *) echo "未知子命令: $1" >&2; usage >&2; exit 2;;
  esac
}

# 仅当直接执行时跑 main；被 source（单测）时不跑。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

- [ ] **Step 4: 设可执行权限 + 跑单测确认通过**

Run:
```bash
chmod +x plugins/mccl-digital-employee/bin/mccl-queue-scheduler plugins/mccl-digital-employee/tests/test-queue.sh
bash plugins/mccl-digital-employee/tests/test-queue.sh
```
Expected: 17 条 `ok:`，末尾 `queue 测试全部通过`，退出码 0。

- [ ] **Step 5: 手动验 --help（不变式21 将依赖此）**

Run: `plugins/mccl-digital-employee/bin/mccl-queue-scheduler --help; echo "退出码=$?"`
Expected: 退出码 0，输出含 `submit`/`status`/`pause`/`stop`/`resume`。

- [ ] **Step 6: 验无裸 ssh（scheduler 不直接 ssh，prober 自己处理远程）**

Run:
```bash
bare=$(grep -nE '\b(ssh|scp)\s+[^\x{4e00}-\x{9fff}\x{ff00}-\x{ffef}]' plugins/mccl-digital-employee/bin/mccl-queue-scheduler | grep -v 'MCCL_SSH_OPTS' | grep -v '^[0-9]*: *#' || true)
[ -z "$bare" ] && echo "ok: 无裸 ssh/scp" || { echo "FAIL: 裸 ssh/scp："; echo "$bare"; }
```
Expected: `ok: 无裸 ssh/scp`（scheduler 不直接 ssh，调 prober 处理远程）。

- [ ] **Step 7: 提交**

```bash
git add plugins/mccl-digital-employee/bin/mccl-queue-scheduler plugins/mccl-digital-employee/tests/test-queue.sh
git commit -m "feat(mccl): 队列调度器 bin/mccl-queue-scheduler + 纯函数单测

范式A：cron每5分钟触发（无参数=调度循环），或控制子命令(submit/status/
pause/stop/resume/list/complete)。无状态，状态全在 .mccl-bench-queue/queue.json。
调度循环输出 DISPATCH/WAIT/STOP/SKIP 供 CronCreate 触发的 Claude 会话消费。
READY 交 Claude 跑 /mccl-bench（bash 不调 Claude 命令）。

纯函数 queue_head_pending_id/queue_set_status/queue_set_field/add_task/
has_pause_flag/has_stop_flag 可 source 单测；schedule_loop 远程编排无法本地验证。
prober 连续12轮error判FAILED。"
```

---

### Task 2: commands/mccl-bench-queue.md 控制命令

**Files:**
- Create: `plugins/mccl-digital-employee/commands/mccl-bench-queue.md`

**Interfaces:**
- Consumes: `bin/mccl-queue-scheduler`（Task 1 的子命令）；queue.json schema
- Produces: 命令名 `mccl-bench-queue`（Task 3 不变式22 校验）

- [ ] **Step 1: 写命令定义**

Create `plugins/mccl-digital-employee/commands/mccl-bench-queue.md`:

```markdown
---
description: bench 队列控制（提交/查看/暂停/终止/恢复）-- 子系统⑥⑦
---

你是 MCCL bench 队列的控制入口。用户输入 `/mccl-bench-queue <子命令>`，你把它翻译成 `bin/mccl-queue-scheduler` 的子命令调用。

## 解析子命令

| 用户输入 | 你执行的 Bash | 说明 |
|---|---|---|
| `/mccl-bench-queue submit <描述> [--rounds N] [--compare]` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" submit "<描述>" --rounds N --compare` | 提交任务入队，返回 task_id |
| `/mccl-bench-queue status [task_id]` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" status` | 显示队列 |
| `/mccl-bench-queue pause` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" pause` | 全局暂停 |
| `/mccl-bench-queue stop <task_id>` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" stop <task_id>` | 终止任务 |
| `/mccl-bench-queue resume` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" resume` | 恢复调度 |
| `/mccl-bench-queue list` | `bash "$TOOLKIT_ROOT/bin/mccl-queue-scheduler" list` | 列出任务 |

## 开工前

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
```

## 你的职责

- 把用户子命令翻译成 `bin/mccl-queue-scheduler` 的 Bash 调用，执行，把输出原样转述给用户。
- **不得**自己解析或改写 queue.json（让脚本做确定性操作）。
- **不得**自己跑 /mccl-bench（那是 CronCreate 触发的调度循环的活，不是控制命令的活）。
- submit 后告诉用户 task_id 和"用 /mccl-bench-queue status 查看进度"。

## 队列状态文件

队列状态在 `$REPO_ROOT/.mccl-bench-queue/`（gitignore）：queue.json / pause.flag / stop-<task_id>.flag / scheduler.log。控制子命令读写这些文件。
```

- [ ] **Step 2: 自检（不变式6 frontmatter + 不变式13 无裸ssh）**

Run: `bash plugins/mccl-digital-employee/tests/check.sh 2>&1 | tail -3`
Expected: `全部通过`（命令文件无 frontmatter name 字段--只有 description，这是命令的合法形态；正文无 ssh/scp，调的是 bash 脚本）。

- [ ] **Step 3: 提交**

```bash
git add plugins/mccl-digital-employee/commands/mccl-bench-queue.md
git commit -m "command: /mccl-bench-queue 队列控制命令

thin dispatcher：把 submit/status/pause/stop/resume/list 子命令翻译成
bin/mccl-queue-scheduler 的 Bash 调用。不自己解析 queue.json、不跑 /mccl-bench。"
```

---

### Task 3: safety 第10条 + check.sh 不变式21/22/23 + 负向测试

**Files:**
- Modify: `plugins/mccl-digital-employee/references/mccl-safety.md`（追加第10行）
- Modify: `plugins/mccl-digital-employee/tests/check.sh`（加不变式21/22/23）

**Interfaces:**
- Consumes: Task 1 的 `bin/mccl-queue-scheduler`、Task 2 的 `commands/mccl-bench-queue.md`、`tests/test-queue.sh`
- Produces: 不变式21（调度器存在+可执行+help）、22（命令含5子命令名）、23（queue.json schema 闭环）+ 负向测试

- [ ] **Step 1: safety.md 追加第10行**

在 `references/mccl-safety.md` 的第9行（`| 9 | ... | ABORT |`）之后插入：

```
| 10 | 调度器（`bin/mccl-queue-scheduler`）stop 只 kill 自己起的 /mccl-bench 测试进程，不杀无关进程、不重启节点 | ABORT |
```

- [ ] **Step 2: 在 check.sh 不变式20b 之后插入 21/22/23**

在 `tests/check.sh` 的 `# --- 20b. ...` 块之后、`echo` 汇总之前插入：

```bash
# --- 21. bin/mccl-queue-scheduler 存在、可执行、--help 合法 ---
qs="$PLUGIN_ROOT/bin/mccl-queue-scheduler"
if [ ! -f "$qs" ]; then
  err "$qs 缺失"
elif [ ! -x "$qs" ]; then
  err "$qs 不可执行"
else
  help_out=$("$qs" --help 2>&1); help_rc=$?
  if [ "$help_rc" -ne 0 ]; then
    err "$qs --help 退出码非 0 ($help_rc)"
  else
    for kw in submit status pause stop resume; do
      echo "$help_out" | grep -q -- "$kw" || err "$qs --help 未提及 $kw"
    done
    [ "$fail" -eq 0 ] && ok "bin/mccl-queue-scheduler --help 合法" || true
  fi
fi

# --- 22. mccl-bench-queue 命令存在且含 submit/status/pause/stop/resume 子命令名 ---
qcf="$PLUGIN_ROOT/commands/mccl-bench-queue.md"
if [ ! -f "$qcf" ]; then
  err "$qcf 缺失"
else
  for kw in submit status pause stop resume; do
    grep -q -- "$kw" "$qcf" || err "$qcf 未提及子命令 $kw"
  done
  ok "mccl-bench-queue 命令子命令齐全"
fi

# --- 23. test-queue.sh 存在、可执行、通过（功能单测）---
tq="$PLUGIN_ROOT/tests/test-queue.sh"
if [ ! -f "$tq" ]; then
  err "$tq 缺失"
elif [ ! -x "$tq" ]; then
  err "$tq 不可执行"
else
  if bash "$tq" >/tmp/mccl_tq.out 2>&1; then
    ok "test-queue.sh 功能单测通过"
  else
    err "test-queue.sh 单测失败"
    cat /tmp/mccl_tq.out | sed 's/^/        /' >&2
  fi
fi
```

- [ ] **Step 3: 跑自检，确认 21/22/23 全通过**

Run: `bash plugins/mccl-digital-employee/tests/check.sh 2>&1 | tail -8`
Expected: 新增 `ok: bin/mccl-queue-scheduler --help 合法`、`ok: mccl-bench-queue 命令子命令齐全`、`ok: test-queue.sh 功能单测通过`，末尾 `全部通过`，退出码 0。

- [ ] **Step 4: 负向测试--不变式22 能抓到子命令缺失**

Run:
```bash
cp plugins/mccl-digital-employee/commands/mccl-bench-queue.md /tmp/qcmd.bak
sed -i 's/submit/dispatch/g' plugins/mccl-digital-employee/commands/mccl-bench-queue.md
bash plugins/mccl-digital-employee/tests/check.sh >/tmp/neg.out 2>&1 || true
grep -qE 'FAIL.*未提及子命令 submit' /tmp/neg.out && echo "负向命中" || echo "负向未命中"
cp /tmp/qcmd.bak plugins/mccl-digital-employee/commands/mccl-bench-queue.md
```
Expected: `负向命中`。

- [ ] **Step 5: 负向测试--不变式23 能抓到单测失败（破坏 add_task）**

Run:
```bash
cp plugins/mccl-digital-employee/bin/mccl-queue-scheduler /tmp/qs.bak
sed -i 's/"status":"PENDING"/"status":"QUEUED"/' plugins/mccl-digital-employee/bin/mccl-queue-scheduler
bash plugins/mccl-digital-employee/tests/check.sh >/tmp/neg.out 2>&1 || true
grep -qE 'FAIL.*test-queue' /tmp/neg.out && echo "负向命中" || echo "负向未命中"
cp /tmp/qs.bak plugins/mccl-digital-employee/bin/mccl-queue-scheduler
```
Expected: `负向命中`（PENDING 改 QUEUED 后，submit 测试断言 PENDING 失败）。

- [ ] **Step 6: 最终全量自检**

Run: `bash plugins/mccl-digital-employee/tests/check.sh; echo "退出码=$?"`
Expected: 全部 `ok:`，`全部通过`，退出码 0。

- [ ] **Step 7: 提交**

```bash
git add plugins/mccl-digital-employee/references/mccl-safety.md plugins/mccl-digital-employee/tests/check.sh
git commit -m "check: 加不变式21/22/23 守队列调度器 + safety 第10条

21: mccl-queue-scheduler 存在/可执行/--help 合法(含5子命令名)。
22: mccl-bench-queue 命令含 submit/status/pause/stop/resume。
23: test-queue.sh 单测通过。
safety 第10条: scheduler stop 只 kill 自己起的测试进程，不杀无关/不重启。

每条配负向测试（破坏->FAIL->恢复）。远程行为(cron/flock/prober/派发)无法本地验证。"
```

---

### Task 4: README 追加"环境排队与定时任务"小节

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 用户文档（含 CronCreate 设置说明）

- [ ] **Step 1: 在 README「测试矩阵与前后对比」一节之后追加「环境排队与定时任务」小节**

在 `README.md` 的 `## 测试矩阵与前后对比（/mccl-bench）` 一节之后（`## 出问题怎么查` 之前），插入：

```markdown
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

**调度器怎么跑**：`bin/mccl-queue-scheduler`（无参数=调度循环）被 cron 触发时：flock 加锁 -> 读 `.mccl-bench-queue/queue.json` -> 检查 pause/stop 标志 -> 调 prober 探测 -> READY 输出 `DISPATCH:<task_id>:<params>` 交 Claude 跑 `/mccl-bench` -> NOT_READY 输出 `WAIT` 等下轮。无状态、崩溃下轮 cron 恢复。

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
```

- [ ] **Step 2: 自检（不变式3 无 IP 泄漏）**

Run: `bash plugins/mccl-digital-employee/tests/check.sh 2>&1 | tail -2`
Expected: `全部通过`。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "README: 追加环境排队与定时任务（/mccl-bench-queue）小节

用法+控制命令+CronCreate定时设置+调度器流程+已知限制（stop分钟级、
CronCreate 7天过期、单任务串行、12轮error判FAILED、远程未端到端验证）。"
```

---

## Self-Review

**1. Spec coverage** - 逐节核对：

| Spec 节 | 覆盖任务 |
|---|---|
| §3.1 范式A cron调CLI无daemon | Task 1（schedule_loop 单次执行）+ Task 4（CronCreate 说明） |
| §3.2 单一队列两入口 | Task 1（submit 子命令）+ Task 4（CronCreate submit） |
| §3.3 复用MCCL_NODES | Task 1（resolve_roots eval loader；prober 读 MCCL_NODES） |
| §3.4 控制接口CLI子命令 | Task 1（6子命令）+ Task 2（命令dispatcher） |
| §3.5 stop分钟级 | Task 1（complete 子命令+stop flag检查）+ Task 4（已知限制） |
| §3.6 固定5分钟 | Task 4（CronCreate 说明） |
| §3.7 确定性脚本不AI推理 | Task 1（bash纯函数+schedule_loop） |
| §4.1 scheduler | Task 1 |
| §4.2 控制命令 | Task 2 |
| §4.3 CronCreate | Task 4 |
| §5 数据流 | Task 1（schedule_loop）+ Task 4（CronCreate提示） |
| §6 状态文件布局 | Task 1（QUEUE_DIR 文件操作） |
| §7 错误处理 | Task 1（flock/pause/stop/NOT_READY/12轮error） |
| §8 测试策略 | Task 1（test-queue.sh）+ Task 3（不变式21-23+负向） |
| §9 Known Limitations | Task 4（README） |
| §10 实现件清单 | 全 4 任务覆盖 6 件 |
| §11 YAGNI 边界 | Task 1（无daemon/无机器池/串行） |

无遗漏。

**2. Placeholder scan** - 无 TBD/TODO。每个负向测试给完整命令。脚本/命令/模板都是完整可读内容。schedule_loop 的 /mccl-bench 派发是输出 DISPATCH 交 Claude（bash 调不了 Claude 命令），README 的 CronCreate 提示说明消费方式--不是占位，是设计。

**3. Type consistency** - 交叉核对：
- queue.json schema：Task 1 add_task 产出（task_id/desc/params/status/submitted_at/progress/rounds_done/run_dir/probe_errors）-> Task 1 queue_set_status/queue_set_field 改 -> Task 2 命令引用 -> Task 3 不变式23 单测覆盖 ✓
- scheduler 输出契约 DISPATCH/WAIT/STOP/SKIP：Task 1 schedule_loop 产出 -> Task 4 README CronCreate 提示消费 ✓
- 子命令名 submit/status/pause/stop/resume/list/complete：Task 1 定义 -> Task 2 命令引用 -> Task 3 不变式22 校验前5个 ✓
- 状态值 PENDING/RUNNING/STOPPED/DONE/FAILED：Task 1 add_task(PENDING)/schedule_loop(RUNNING)/cmd_complete(DONE/FAILED/STOPPED) 一致 ✓

## 验证能力的诚实边界

能验的：队列读写纯函数（Task 1 单测）、控制子命令（Task 1 单测）、--help、静态不变式（Task 3）、负向测试。**不能验的**：schedule_loop 的 flock/prober 调用/DISPATCH 输出在真实 cron 下的行为、CronCreate 触发的 Claude 会话消费 DISPATCH 并跑 /mccl-bench、stop flag 在 /mccl-bench 完成后检查的时序、12轮error退避在真实环境的触发。后者需真实仓库+远程节点，本仓库做不到。每个新增不变式配负向测试。
