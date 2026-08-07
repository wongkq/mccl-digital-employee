#!/usr/bin/env bash
# 时间线日志 hook：把每个事件（本地工具执行 / LLM 推理空窗分界）追加到仓库根 .mccl-timing.log
# hook stdin JSON: {"session_id":"...","tool_name":"Bash","tool_input":{...}}（Stop/UserPromptSubmit 无 tool_name）
# 用法 view：awk -F'\t' '{print $1, $2, $3}' .mccl-timing.log
set -uo pipefail
event="${1:?用法: timing-log.sh <PRE|POST|STOP|PROMPT>}"
repo="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
log="$repo/.mccl-timing.log"
ts="$(date '+%F %T.%3N')"
json="$(cat 2>/dev/null || true)"
tool="$(printf '%s' "$json" | jq -r '.tool_name // "?"' 2>/dev/null || echo '?')"
printf '%s\t%s\t%s\n' "$ts" "$event" "$tool" >> "$log"
