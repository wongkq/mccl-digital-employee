#!/usr/bin/env bash
# tests/test-gpu-probe.sh - bin/mccl-gpu-probe 纯函数与 JSON 形态的本地验证。
# 远程行为（mx-smi/带宽/占用）无法本地验证，见 spec §7 诚实边界。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
PROBE="$PLUGIN_ROOT/bin/mccl-gpu-probe"

pass=0; fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok:   $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}

# source 纯函数（BASH_SOURCE 守卫保证不触发 main）
# shellcheck source=/dev/null
. "$PROBE" 2>/dev/null || { echo "FAIL: 无法 source $PROBE（文件不存在？）" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. parse_health_stats：mock health_report.txt（含字面 \033 颜色码，仿真实输出）---
cat > "$TMP/health_report.txt" <<'EOF'
============================================
 GPU 集群通信健康检测报告
============================================

── 测试统计 ──
  总测试项:     84
  \033[0;32m通过 (优秀):  80\033[0m
  \033[1;33m警告 (偏低):  2\033[0m
  \033[0;31m失败 (异常):  1\033[0m
  错误:         1
  可用率:       97.6%
EOF
out=$(parse_health_stats "$TMP/health_report.txt")
assert_eq "parse FAIL"  "1"  "$(printf '%s' "$out" | grep -oP 'FAIL=\K[0-9]+')"
assert_eq "parse ERROR" "1"  "$(printf '%s' "$out" | grep -oP 'ERROR=\K[0-9]+')"
assert_eq "parse WARN"  "2"  "$(printf '%s' "$out" | grep -oP 'WARN=\K[0-9]+')"
assert_eq "parse PASS"  "80" "$(printf '%s' "$out" | grep -oP 'PASS=\K[0-9]+')"
assert_eq "parse TOTAL" "84" "$(printf '%s' "$out" | grep -oP 'TOTAL=\K[0-9]+')"

# --- 2. parse_health_stats：文件缺失返回全 0 + 退出码 1 ---
out=$(parse_health_stats "$TMP/nope.txt"); rc=$?
assert_eq "missing rc=1"      "1" "$rc"
assert_eq "missing all-zero"  "FAIL=0 ERROR=0 WARN=0 PASS=0 TOTAL=0" "$out"

# --- 3. assemble_verdict（fail error warn occupied topo_ok bins_ok）---
assert_eq "topo bad"         "NOT_READY" "$(assemble_verdict 1 0 0 0 0 1)"
assert_eq "bins bad"         "NOT_READY" "$(assemble_verdict 0 0 0 0 1 0)"
assert_eq "occupied"         "NOT_READY" "$(assemble_verdict 0 0 0 1 1 1)"
assert_eq "bw fail"          "NOT_READY" "$(assemble_verdict 1 0 0 0 1 1)"
assert_eq "bw error"         "NOT_READY" "$(assemble_verdict 0 1 0 0 1 1)"
assert_eq "warn still READY" "READY"     "$(assemble_verdict 0 0 2 0 1 1)"
assert_eq "all green"        "READY"     "$(assemble_verdict 0 0 0 0 1 1)"

# --- 4. emit_json 形态：verdict 字段 + 合法 JSON + failures 计数 ---
export V_VERDICT=NOT_READY V_MODE=full V_NNODES=4 V_GPUS=8 V_TMODE=OAM32 V_TOPO_OK=1
export V_BW_FAIL=1 V_BW_ERROR=0 V_BW_WARN=0 V_BW_CACHED=0 V_BW_REPORT="./r/health_report.txt"
export V_OCC_JSON='{"all_free":false,"occupied":[{"host":"h","procs":["pid 1"]}]}'
export V_HOSTS_JSON='[]'
export V_BINS_SYM=1 V_BINS_ASYM=1 V_BINS_MPI=1 V_EVIDENCE_LOGS="./r/logs"
export V_FAILURES=$'10.x.x.x gpu3 被进程占用\n带宽告警: OM h0->h1 偏低'
doc=$(emit_json)
v=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])')
assert_eq "emit verdict" "NOT_READY" "$v"
occ=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["occupancy"]["all_free"])')
assert_eq "emit occupancy False" "False" "$occ"
nf=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["failures"]))')
assert_eq "emit failures count 2" "2" "$nf"

# --- 5. check_occupancy：ssh 失败必须 return 2（不可达节点不能静默判空闲）---
# 覆盖 ssh_exec_read 模拟失败；MCCL_NODES 设 1 节点。验三件事：
#   a) 函数返回码 == 2（让 call-site 的 || guard 激活）
#   b) OCC_FAILURES 记录到该节点（诊断信息）
#   c) OCC_JSON 的 all_free 不是 true（不能误判为空闲）
# 真远程校验留给现场 test-engineer；本地只能跑 mock。
ssh_exec_read() { return 1; }
MCCL_NODES="1.2.3.4"
check_occupancy; occ_rc=$?
assert_eq "occ ssh-fail return 2" "2" "$occ_rc"
echo "$OCC_FAILURES" | grep -q '1.2.3.4' || assert_eq "occ ssh-fail recorded host" "present" "absent"
echo "$OCC_JSON" | grep -q '"all_free":false' || assert_eq "occ ssh-fail all_free=false" "false" "true"
# 恢复 ssh_exec_read 防止污染后续 case
unset -f ssh_exec_read
# shellcheck source=/dev/null
. "$PROBE" 2>/dev/null

# --- 6. extract_gpu_pids：Processes 段提取 PID（去重、剔除 PID<=1、跳过表头）---
mxsmi_out='Attached GPUs: 8
+------------------------------+
| MCCL Version: 3.1.0          |
+------------------------------+

Processes:
  GPU    PID   Type  Process name
    0    1234   C    python train.py
    1    1234   C    python train.py
    2    5678   C    ./a.out
    3       1   C    systemd
  No running processes found'
assert_eq "pids dedup/sorted/gt1" "1234 5678" "$(extract_gpu_pids "$mxsmi_out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "pids empty when no proc" "" "$(extract_gpu_pids 'Attached GPUs: 8
Processes:
  No running processes found')"

# --- 7. emit_json：occupancy.killed 审计字段（--free-occupied 清理记录）---
export V_VERDICT=READY V_MODE=quick V_NNODES=4 V_GPUS=8 V_TMODE=OAM32 V_TOPO_OK=1
export V_BW_FAIL=0 V_BW_ERROR=0 V_BW_WARN=0 V_BW_CACHED=0 V_BW_REPORT=""
export V_OCC_JSON='{"all_free":true,"occupied":[]}'
export V_KILLS_JSON='[{"host":"h1","pid":123,"action":"killed(term,10s后存活则kill-9)","cmd":""},{"host":"h1","pid":456,"action":"skip-流水线进程或cmdline不可查","cmd":"mpirun ..."}]'
export V_HOSTS_JSON='[]' V_BINS_SYM=1 V_BINS_ASYM=1 V_BINS_MPI=1 V_EVIDENCE_LOGS="" V_FAILURES=""
doc=$(emit_json)
kn=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["occupancy"]["killed"]))')
assert_eq "emit killed count 2" "2" "$kn"
ka=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["occupancy"]["killed"][0]["action"])')
assert_eq "emit killed[0].action" "killed(term,10s后存活则kill-9)" "$ka"
# 未传 V_KILLS_JSON 时 killed 默认空数组（向后兼容旧调用）
unset V_KILLS_JSON
doc=$(emit_json)
kn=$(printf '%s' "$doc" | python3 -c 'import json,sys;print(json.load(sys.stdin)["occupancy"]["killed"])')
assert_eq "emit killed default []" "[]" "$kn"

echo
[ "$fail" -eq 0 ] && echo "gpu-probe 测试全部通过 ($pass)" || echo "gpu-probe 测试有失败 ($fail)"
exit "$fail"
