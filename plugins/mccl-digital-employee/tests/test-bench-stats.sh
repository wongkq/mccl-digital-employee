#!/usr/bin/env bash
# tests/test-bench-stats.sh - bin/mccl-bench-stats.py 聚合纯函数的本地验证。
# 喂 mock 的 perf 日志行，验 mean/min/max 与 bench-stats.json schema。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
STATS="$PLUGIN_ROOT/bin/mccl-bench-stats.py"

# bench 是独立单测，不 source mccl-env-load.py；占位默认值（build_run 的 bin 字段不被断言）。
MCCL_PERF_BIN_SYM="${MCCL_PERF_BIN_SYM:-/dummy/sym}"

pass=0; fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok:   $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}
[ -f "$STATS" ] || { echo "FAIL: $STATS 不存在" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. parse_perf_line：从一行 perf 输出提取 algbw/busbw ---
# 仿 all_reduce_perf 输出形如 "size 1024 algbw 95.2 busbw 180.0"
line="size 1024 algbw 95.2 busbw 180.0"
out=$(python3 "$STATS" parse_perf_line "$line")
assert_eq "parse algbw" "95.2" "$(printf '%s' "$out" | grep -oP 'algbw=\K[0-9.]+')"
assert_eq "parse busbw" "180.0" "$(printf '%s' "$out" | grep -oP 'busbw=\K[0-9.]+')"

# --- 2. aggregate_metrics：3 个值算 mean/min/max ---
# 输入：每行一个 "algbw <v> busbw <v>"，输出 JSON {"algbw_GBs":{mean,min,max},"busbw_GBs":{...}}
printf 'algbw 95.2 busbw 180.0\nalgbw 94.1 busbw 178.0\nalgbw 96.0 busbw 182.0\n' > "$TMP/in.txt"
mj=$(python3 "$STATS" aggregate_metrics "$TMP/in.txt")
assert_eq "agg algbw mean" "95.1" "$(printf '%s' "$mj" | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["algbw_GBs"]["mean"],1))')"
assert_eq "agg algbw min"  "94.1" "$(printf '%s' "$mj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["algbw_GBs"]["min"])')"
assert_eq "agg algbw max"  "96.0" "$(printf '%s' "$mj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["algbw_GBs"]["max"])')"
assert_eq "agg busbw mean" "180.0" "$(printf '%s' "$mj" | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["busbw_GBs"]["mean"],1))')"

# --- 3. 单点（1轮）：mean=min=max ---
printf 'algbw 95.2 busbw 180.0\n' > "$TMP/in1.txt"
m1=$(python3 "$STATS" aggregate_metrics "$TMP/in1.txt")
assert_eq "single mean=min" "95.2" "$(printf '%s' "$m1" | python3 -c 'import json,sys;d=json.load(sys.stdin)["algbw_GBs"];print(d["mean"])')"
assert_eq "single max=min"  "95.2" "$(printf '%s' "$m1" | python3 -c 'import json,sys;d=json.load(sys.stdin)["algbw_GBs"];print(d["max"])')"

# --- 4. build_run：组装一个 so_tag 的完整 run JSON ---
# 输入：so_tag, rounds, 然后每场景一行 "<id>|<bin>|<params>|<metrics_json>"
rj=$(python3 "$STATS" build_run after 3 \
  "sym-1k|$MCCL_PERF_BIN_SYM|-b 1k -e 1k -f 2 -R 2|{\"algbw_GBs\":{\"mean\":95.2,\"min\":94.1,\"max\":96.0},\"busbw_GBs\":{\"mean\":180.0,\"min\":178.0,\"max\":182.0}}")
sid=$(printf '%s' "$rj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["scenarios"][0]["id"])')
assert_eq "build_run scenario id" "sym-1k" "$sid"
assert_eq "build_run rounds" "3" "$(printf '%s' "$rj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["scenarios"][0]["rounds"])')"
assert_eq "build_run so_tag" "after" "$(printf '%s' "$rj" | python3 -c 'import json,sys;print(json.load(sys.stdin)["so_tag"])')"

echo
[ "$fail" -eq 0 ] && echo "bench-stats 测试全部通过 ($pass)" || echo "bench-stats 测试有失败 ($fail)"
exit "$fail"
