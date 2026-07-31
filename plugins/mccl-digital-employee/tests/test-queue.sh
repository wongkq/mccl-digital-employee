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
