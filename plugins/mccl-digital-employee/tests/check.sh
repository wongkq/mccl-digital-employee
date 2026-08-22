#!/usr/bin/env bash
# MCCL数字员工工具包自检。每次commit前跑：bash plugins/mccl-digital-employee/tests/check.sh
# 只验证静态不变式。agent的实际行为需拷入真实仓库后验证。
#
# 双根：仓库级检查（#1-5）用 REPO_ROOT（git仓库根，测试.md/mccl-env.json/settings.json所在处）；
# 插件级检查（#6-12）用 PLUGIN_ROOT（本脚本所在插件的根，agents/references/所在处）。
# 两者在marketplace布局下不是同一目录，混用会查错地方。
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "ok:   $*"; }

# ============ 仓库级（REPO_ROOT） ============

# --- 1. 测试.md 从未进入 git 历史 ---
if git -C "$REPO_ROOT" log --all --pretty=format: --name-only 2>/dev/null | grep -qx '测试.md'; then
  err "测试.md 出现在 git 历史中（不可逆，需 filter-branch 清理）"
else
  ok "测试.md 不在 git 历史中"
fi

# --- 2. 测试.md 当前被忽略 ---
if git -C "$REPO_ROOT" check-ignore -q 测试.md 2>/dev/null; then
  ok "测试.md 被 .gitignore 拦截"
elif [ -e "$REPO_ROOT/测试.md" ]; then
  err "测试.md 存在但未被忽略"
else
  ok "测试.md 不存在于工作区"
fi

# --- 3. 已跟踪文件不得含私网IP字面量 ---
ip_hits=$(cd "$REPO_ROOT" && git ls-files -z | xargs -0 grep -lE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' 2>/dev/null || true)
if [ -n "$ip_hits" ]; then
  err "已跟踪文件含私网IP：$ip_hits"
else
  ok "已跟踪文件无私网IP字面量"
fi

# --- 4. mccl-env.json 不得被跟踪 ---
if git -C "$REPO_ROOT" ls-files --error-unmatch mccl-env.json >/dev/null 2>&1; then
  err "mccl-env.json 被跟踪（含内网信息，应只提交 .example）"
else
  ok "mccl-env.json 未被跟踪"
fi

# --- 5. settings.json 合法且含关键 deny 规则 ---
settings_file="$REPO_ROOT/.claude/settings.json"
if [ ! -f "$settings_file" ]; then
  err "$settings_file 缺失"
elif ! python3 -c "import json,sys; json.load(open('$settings_file'))" 2>/dev/null; then
  err "$settings_file 不是合法JSON"
else
  missing=$(python3 - "$settings_file" <<'PY'
import json, sys
need = {"Bash(git push:*)", "Bash(reboot:*)", "Bash(shutdown:*)"}
have = set(json.load(open(sys.argv[1])).get("permissions", {}).get("deny", []))
print(" ".join(sorted(need - have)))
PY
)
  if [ -n "$missing" ]; then
    err "settings.json 缺少 deny 规则：$missing"
  else
    ok "settings.json 合法且含关键 deny 规则"
  fi
fi

# ============ 插件级（PLUGIN_ROOT） ============

# --- 6. agent frontmatter 完整 ---
for f in "$PLUGIN_ROOT"/agents/*.md; do
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

# --- 7. agent 引用的 MCCL_ 变量都在 mccl-env.json.example + loader 派生集合中 ---
example_json="$PLUGIN_ROOT/mccl-env.json.example"
loader="$PLUGIN_ROOT/bin/mccl-env-load.py"
if [ ! -f "$example_json" ] || [ ! -f "$loader" ]; then
  err "缺 $example_json 或 $loader，无法校验引用闭合"
else
  # loader --keys 对 example 跑一次，拿到全部变量名（raw 24 + derived 8）
  all_keys="$(python3 "$loader" "$example_json" --keys 2>/dev/null | sort -u)"
  undef=""
  for v in $(grep -rhoE '\$\{?MCCL_[A-Z0-9_]+' "$PLUGIN_ROOT/agents/" "$PLUGIN_ROOT/commands/" "$PLUGIN_ROOT/references/" "$PLUGIN_ROOT/bin/" 2>/dev/null \
             | sed 's/[${]//g' | sort -u); do
    echo "$all_keys" | grep -qx "$v" || undef="$undef $v"
  done
  if [ -n "$undef" ]; then
    err "引用了未在 mccl-env.json.example/loader 中定义的变量：$undef"
  else
    ok "环境变量引用闭合（raw + derived）"
  fi
fi

# --- 8. mccl-reporter 不得拥有 Bash（防报告造假的物理隔离）---
rf="$PLUGIN_ROOT/agents/mccl-reporter.md"
if [ ! -f "$rf" ]; then
  err "$rf 缺失"
elif awk '/^---$/{n++; next} n==1' "$rf" | sed -n 's/^tools: *//p' | grep -qw 'Bash'; then
  err "$rf 的 tools 含 Bash——报告工程师必须无执行能力"
else
  ok "mccl-reporter 无 Bash"
fi

# --- 9. /mccl-run 已标注废弃（依赖已移除的 developer/supervisor）---
cf="$PLUGIN_ROOT/commands/mccl-run.md"
if [ ! -f "$cf" ]; then
  err "$cf 缺失"
elif grep -qE "已废弃|DEPRECATED" "$cf"; then
  ok "/mccl-run 已标注废弃"
else
  err "$cf 未标注废弃（依赖已移除的 mccl-developer/mccl-supervisor）"
fi

# --- 10. supervisor-checklists 已随 supervisor 移除 ---
if [ -d "$PLUGIN_ROOT/references/supervisor-checklists" ]; then
  err "supervisor-checklists 目录仍存在，但 mccl-supervisor 已移除"
else
  ok "supervisor-checklists 已随 supervisor 移除"
fi

# --- 11. bin/mccl-toolkit-root 存在、可执行，且自举校验通过 ---
tk="$PLUGIN_ROOT/bin/mccl-toolkit-root"
if [ ! -f "$tk" ]; then
  err "$tk 缺失"
elif [ ! -x "$tk" ]; then
  err "$tk 不可执行"
else
  # 三路自举验证：QODER_PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT / BASH_SOURCE 兜底。
  # 显式unset 两个插件环境变量，强制走BASH_SOURCE反推兜底路径——验证"项目内拷贝"装法
  # （两种工具都不依赖插件环境变量）确实成立；再分别设 QODER/CLAUDE 环境变量验插件装法。
  boot_out="$(cd "$PLUGIN_ROOT" && env -u CLAUDE_PLUGIN_ROOT -u QODER_PLUGIN_ROOT "$tk" 2>/dev/null)"
  qoder_out="$(cd "$PLUGIN_ROOT" && env -u CLAUDE_PLUGIN_ROOT QODER_PLUGIN_ROOT="$PLUGIN_ROOT" "$tk" 2>/dev/null)"
  claude_out="$(cd "$PLUGIN_ROOT" && env -u QODER_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$tk" 2>/dev/null)"
  if [ "$boot_out" = "$PLUGIN_ROOT" ] && [ "$qoder_out" = "$PLUGIN_ROOT" ] && [ "$claude_out" = "$PLUGIN_ROOT" ]; then
    ok "bin/mccl-toolkit-root 三路自举校验通过（QODER/CLAUDE_PLUGIN_ROOT/BASH_SOURCE 兜底）"
  else
    err "bin/mccl-toolkit-root 自举校验失败：期望 $PLUGIN_ROOT，实得 boot='$boot_out' qoder='$qoder_out' claude='$claude_out'"
  fi
fi

# --- 12. loader 的节点派生量确实从 MCCL_NODES 派生（跑两个输入验证非写死）---
# 原 .sh 时代靠 grep 派生行引用上游；改 JSON+loader 后派生在 Python 里，
# 改用"跑 loader 对两个不同输入，看派生量是否随输入正确变化"来证明非写死。
example_json="$PLUGIN_ROOT/mccl-env.json.example"
loader="$PLUGIN_ROOT/bin/mccl-env-load.py"
if [ ! -f "$loader" ] || [ ! -f "$example_json" ]; then
  err "loader 或 mccl-env.json.example 缺失，无法校验派生"
else
  # 用 example 作底，覆盖 NODES/GPUS 造两份临时 json（其余键用占位值即可，派生只看 NODES/GPUS）
  both="$(python3 - "$example_json" <<'PY'
import json, sys, os, tempfile
ex = json.load(open(sys.argv[1]))
base = {k: v for k, v in ex.items() if k.startswith("MCCL_")}
def mk(nodes, gpus):
    d = dict(base); d["MCCL_NODES"] = nodes; d["MCCL_GPUS_PER_NODE"] = gpus
    fd, p = tempfile.mkstemp(suffix=".json"); os.write(fd, json.dumps(d).encode()); os.close(fd)
    return p
print(mk("1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4", 8), mk("9.9.9.9", 1))
PY
)"
  j4="${both%% *}"; j1="${both##* }"
  derive_bad=""
  eval "$(python3 "$loader" "$j4")"
  [ "${MCCL_NNODES:-}" = 4 ] && [ "${MCCL_NP:-}" = 32 ] && [ "${MCCL_NODE0_IP:-}" = "1.1.1.1" ] \
    && [ "${MCCL_HOST_SPEC:-}" = "1.1.1.1:8,2.2.2.2:8,3.3.3.3:8,4.4.4.4:8" ] \
    || derive_bad="$derive_bad 4节点输入派生错(NNODES=${MCCL_NNODES:-?} NP=${MCCL_NP:-?} NODE0=${MCCL_NODE0_IP:-?} HOST_SPEC=${MCCL_HOST_SPEC:-?})"
  eval "$(python3 "$loader" "$j1")"
  [ "${MCCL_NNODES:-}" = 1 ] && [ "${MCCL_NP:-}" = 1 ] && [ "${MCCL_NODE0_IP:-}" = "9.9.9.9" ] \
    && [ "${MCCL_HOST_SPEC:-}" = "9.9.9.9:1" ] \
    || derive_bad="$derive_bad 1节点输入派生错(NNODES=${MCCL_NNODES:-?} NP=${MCCL_NP:-?} NODE0=${MCCL_NODE0_IP:-?} HOST_SPEC=${MCCL_HOST_SPEC:-?})"
  rm -f "$j4" "$j1"
  if [ -n "$derive_bad" ]; then
    err "loader 节点派生量有问题：$derive_bad"
  else
    ok "loader 节点派生量（NODE0_IP/NNODES/NP/HOST_SPEC）随输入变化、非写死"
  fi
fi

# --- 12b. 压测参数派生与 override 合并（MCCL_PERF_ARGS / mccl-perf-override.json）---
# 验证三点：默认拼串正确；override 覆盖生效且 MCCL_PERF_OVERRIDDEN_KEYS 记录键名；
# override 含非 MCCL_PERF_* 键时报错退出（防写错键名静默不生效）。
if [ -f "$loader" ] && [ -f "$example_json" ]; then
  odir="$(mktemp -d)"
  cp "$example_json" "$odir/mccl-env.json"
  perf_bad=""
  # 默认值（example 里的 32K/32M/2/20000/1/200/sum/float/100）
  eval "$(python3 "$loader" "$odir/mccl-env.json" 2>/dev/null)"
  [ "${MCCL_PERF_ARGS:-}" = "-b 32K -e 32M -f 2 -n 20000 -c 1 -w 200 -o sum -d float -G 100" ] \
    || perf_bad="$perf_bad 默认MCCL_PERF_ARGS错(${MCCL_PERF_ARGS:-?})"
  [ -z "${MCCL_PERF_OVERRIDDEN_KEYS:-}" ] \
    || perf_bad="$perf_bad 无override时OVERRIDDEN_KEYS应为空(${MCCL_PERF_OVERRIDDEN_KEYS:-?})"
  # override 生效
  echo '{"MCCL_PERF_BEGIN": "16K", "MCCL_PERF_ITERS": 5000}' > "$odir/mccl-perf-override.json"
  eval "$(python3 "$loader" "$odir/mccl-env.json" 2>/dev/null)"
  [ "${MCCL_PERF_ARGS:-}" = "-b 16K -e 32M -f 2 -n 5000 -c 1 -w 200 -o sum -d float -G 100" ] \
    || perf_bad="$perf_bad override后MCCL_PERF_ARGS错(${MCCL_PERF_ARGS:-?})"
  [ "${MCCL_PERF_OVERRIDDEN_KEYS:-}" = "MCCL_PERF_BEGIN MCCL_PERF_ITERS" ] \
    || perf_bad="$perf_bad OVERRIDDEN_KEYS错(${MCCL_PERF_OVERRIDDEN_KEYS:-?})"
  # 非 MCCL_PERF_* 键必须报错
  echo '{"MCCL_NODES": "1.2.3.4"}' > "$odir/mccl-perf-override.json"
  if python3 "$loader" "$odir/mccl-env.json" >/dev/null 2>&1; then
    perf_bad="$perf_bad 非perf键的override未报错"
  fi
  # 未知 perf 键必须报错
  echo '{"MCCL_PERF_XXX": "1"}' > "$odir/mccl-perf-override.json"
  if python3 "$loader" "$odir/mccl-env.json" >/dev/null 2>&1; then
    perf_bad="$perf_bad 未知perf键的override未报错"
  fi
  # 非整数 ITERS 必须报错
  echo '{"MCCL_PERF_ITERS": "abc"}' > "$odir/mccl-perf-override.json"
  if python3 "$loader" "$odir/mccl-env.json" >/dev/null 2>&1; then
    perf_bad="$perf_bad 非整数ITERS未报错"
  fi
  rm -rf "$odir"
  if [ -n "$perf_bad" ]; then
    err "loader 压测参数/override 有问题：$perf_bad"
  else
    ok "loader 压测参数派生与 override 合并正确（含非法键/非整数拒绝）"
  fi
fi

# --- 13. ssh/scp 必须带 $MCCL_SSH_OPTS（裸 ssh 在密钥没配好时会弹密码提示，
#         而 agent 的 Bash 背后没有人输密码，等于卡死）---
bare="$(grep -rn 'ssh root@\|scp [^$]*root@' "$PLUGIN_ROOT/agents/" "$PLUGIN_ROOT/commands/" \
        "$PLUGIN_ROOT/references/" 2>/dev/null | grep -v 'MCCL_SSH_OPTS' | grep -v '<目标节点>' || true)"
if [ -n "$bare" ]; then
  err "有不带 \$MCCL_SSH_OPTS 的裸 ssh/scp（密钥未配时会挂起）："
  echo "$bare" | sed 's/^/        /' >&2
else
  ok "ssh/scp 均带 \$MCCL_SSH_OPTS 防挂起"
fi

# --- 14. bin/mccl-gpu-probe 存在、可执行、--help 合法、无裸 ssh/scp ---
probe="$PLUGIN_ROOT/bin/mccl-gpu-probe"
if [ ! -f "$probe" ]; then
  err "$probe 缺失"
elif [ ! -x "$probe" ]; then
  err "$probe 不可执行"
else
  help_out=$("$probe" --help 2>&1); help_rc=$?
  if [ "$help_rc" -ne 0 ]; then
    err "$probe --help 退出码非 0 ($help_rc)"
  else
    for kw in --mode --hosts --reuse-bw --free-occupied; do
      echo "$help_out" | grep -q -- "$kw" || err "$probe --help 未提及 $kw"
    done
    [ "$fail" -eq 0 ] && ok "bin/mccl-gpu-probe --help 合法" || true
  fi
  # 无裸 ssh/scp：所有 ssh/scp 行必含 $MCCL_SSH_OPTS
  # 注：brief 的 `\b(ssh|scp)\b` 会把 `emit_error_json` 里 CJK 错误消息
  # （"ssh 失败"/"ssh（"）误判为裸 ssh——这些是错误消息文本，非真实调用。
  # 真实调用 5 处全为 `ssh $MCCL_SSH_OPTS`/`scp $MCCL_SSH_OPTS`，后接 $ 或 ASCII 字母；
  # CJK 错误消息的下一字符是 CJK 字符。用 `[^\x{4e00}-\x{9fff}\x{ff00}-\x{ffef}]`
  # （排除 CJK + 全角）做命令形态过滤。Step 4 负向 sed 把 `$MCCL_SSH_OPTS` 删掉后
  # 下一字符变 `"` (ASCII)，本正则仍命中，确保负向测试有效。
  bare_ssh=$(grep -nP '\b(ssh|scp)\s+[^\x{4e00}-\x{9fff}\x{ff00}-\x{ffef}]' "$probe" \
    | grep -v 'MCCL_SSH_OPTS' \
    | grep -v '^[0-9]*: *#' \
    || true)
  if [ -n "$bare_ssh" ]; then
    err "$probe 有不带 \$MCCL_SSH_OPTS 的裸 ssh/scp（密钥未配会挂起）"
    echo "$bare_ssh" | sed 's/^/        /' >&2
  else
    ok "bin/mccl-gpu-probe 无裸 ssh/scp"
  fi
fi

# --- 15. mccl-prober agent frontmatter 完整 + 含 Bash；mccl-run 引用 mccl-prober ---
pf="$PLUGIN_ROOT/agents/mccl-prober.md"
if [ ! -f "$pf" ]; then
  err "$pf 缺失"
else
  pfm_name=$(awk '/^---$/{n++; next} n==1' "$pf" | sed -n 's/^name: *//p')
  [ "$pfm_name" = "mccl-prober" ] || err "$pf 的 name($pfm_name) 与文件名不一致"
  if ! awk '/^---$/{n++; next} n==1' "$pf" | sed -n 's/^tools: *//p' | grep -qw 'Bash'; then
    err "$pf 的 tools 不含 Bash（探测员需跑探测脚本）"
  else
    ok "mccl-prober frontmatter 合法且含 Bash"
  fi
fi
if ! grep -q 'mccl-prober' "$PLUGIN_ROOT/commands/mccl-run.md"; then
  err "mccl-run.md 未引用 mccl-prober（门禁未接入）"
else
  ok "mccl-run.md 引用 mccl-prober"
fi

# --- 16. tests/test-gpu-probe.sh 存在、可执行、通过（功能单测）---
tgp="$PLUGIN_ROOT/tests/test-gpu-probe.sh"
if [ ! -f "$tgp" ]; then
  err "$tgp 缺失"
elif [ ! -x "$tgp" ]; then
  err "$tgp 不可执行"
else
  if bash "$tgp" >/tmp/mccl_tgp.out 2>&1; then
    ok "test-gpu-probe.sh 功能单测通过"
  else
    err "test-gpu-probe.sh 单测失败"
    cat /tmp/mccl_tgp.out | sed 's/^/        /' >&2
  fi
fi

# --- 17. /mccl-bench 已标注废弃（依赖已移除的 developer/supervisor）---
bcf="$PLUGIN_ROOT/commands/mccl-bench.md"
if [ ! -f "$bcf" ]; then
  err "$bcf 缺失"
elif grep -qE "已废弃|DEPRECATED" "$bcf"; then
  ok "/mccl-bench 已标注废弃"
else
  err "$bcf 未标注废弃"
fi

# --- 18. mccl-bench-planner frontmatter 完整 + 含 Bash + 正文含"选择理由"必填提示 ---
pbf="$PLUGIN_ROOT/agents/mccl-bench-planner.md"
if [ ! -f "$pbf" ]; then
  err "$pbf 缺失"
else
  pfm_name=$(awk '/^---$/{n++; next} n==1' "$pbf" | sed -n 's/^name: *//p')
  [ "$pfm_name" = "mccl-bench-planner" ] || err "$pbf 的 name($pfm_name) 与文件名不一致"
  if ! awk '/^---$/{n++; next} n==1' "$pbf" | sed -n 's/^tools: *//p' | grep -qw 'Bash'; then
    err "$pbf 的 tools 不含 Bash（规划员需读 change.patch）"
  else
    ok "mccl-bench-planner frontmatter 合法且含 Bash"
  fi
  # 正文必须提示"选择理由"必填（审计约束的静态守卫）
  grep -q '选择理由' "$pbf" || err "$pbf 正文未提'选择理由'必填（审计约束缺失）"
fi

# --- 19. bench 报告模板存在 ---
if [ ! -f "$PLUGIN_ROOT/references/bench-report-template.md" ]; then
  err "references/bench-report-template.md 缺失（reporter 填数前提）"
else
  ok "bench 报告模板存在"
fi

# --- 20. bench-stats.json schema 闭环：stats 键名 algbw_GBs/busbw_GBs 在模板里出现 ---
tpl="$PLUGIN_ROOT/references/bench-report-template.md"
stats_py="$PLUGIN_ROOT/bin/mccl-bench-stats.py"
if [ -f "$tpl" ] && [ -f "$stats_py" ]; then
  for k in algbw_GBs busbw_GBs; do
    grep -q "$k" "$stats_py" || err "mccl-bench-stats.py 未产出键 $k"
    grep -q "$k" "$tpl" || err "bench-report-template.md 未引用键 $k（schema 不闭环）"
  done
  ok "bench-stats schema 闭环（algbw_GBs/busbw_GBs 在 stats.py 与模板一致）"
fi

# --- 20b. test-bench-stats.sh 存在、可执行、通过（功能单测）---
tbs="$PLUGIN_ROOT/tests/test-bench-stats.sh"
if [ ! -f "$tbs" ]; then
  err "$tbs 缺失"
elif [ ! -x "$tbs" ]; then
  err "$tbs 不可执行"
else
  if bash "$tbs" >/tmp/mccl_tbs.out 2>&1; then
    ok "test-bench-stats.sh 功能单测通过"
  else
    err "test-bench-stats.sh 单测失败"
    cat /tmp/mccl_tbs.out | sed 's/^/        /' >&2
  fi
fi

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

# --- 24. agents/mccl-skill-sync.md 存在且含 git push / git commit / check.sh 三词（同步链闭合）---
sa="$PLUGIN_ROOT/agents/mccl-skill-sync.md"
if [ ! -f "$sa" ]; then
  err "$sa 缺失"
else
  fail24=0
  for kw in "git push" "git commit" "check.sh"; do
    grep -q -- "$kw" "$sa" || { err "$sa 未提及 $kw"; fail24=1; }
  done
  [ "$fail24" = "1" ] || ok "mccl-skill-sync agent 同步链闭合（push/commit/check 齐）"
fi

# --- 25. commands/mccl-skill-sync.md 存在且含 auto 关键字（自动模式入口）---
sc="$PLUGIN_ROOT/commands/mccl-skill-sync.md"
if [ ! -f "$sc" ]; then
  err "$sc 缺失"
else
 fail25=0
  grep -q -- "auto" "$sc" || { err "$sc 未提及 auto"; fail25=1; }
  [ "$fail25" = "1" ] || ok "mccl-skill-sync 命令含 auto 自动模式入口"
fi

# --- 26. agents/mccl-impact-planner.md 存在且含 impact-plan / --scope / **冻结建议** ---
pa="$PLUGIN_ROOT/agents/mccl-impact-planner.md"
if [ ! -f "$pa" ]; then
  err "$pa 缺失"
else
  fail26=0
  for kw in "impact-plan" "--scope" "冻结建议"; do
    grep -q -- "$kw" "$pa" || { err "$pa 未提及 $kw"; fail26=1; }
  done
  [ "$fail26" = "1" ] || ok "mccl-impact-planner agent 关键词齐（impact-plan/scope/冻结建议）"
fi

# --- 27. commands/mccl-impact-run.md 存在且含调度链两关键字（--scope + mccl-impact-planner）---
ic="$PLUGIN_ROOT/commands/mccl-impact-run.md"
if [ ! -f "$ic" ]; then
  err "$ic 缺失"
else
  fail27=0
  for kw in "\-\-scope" "mccl-impact-planner"; do
    grep -q -- "$kw" "$ic" || { err "$ic 未提及 $kw"; fail27=1; }
  done
  [ "$fail27" = "1" ] || ok "mccl-impact-run 命令调度关键字齐（--scope + planner并）"
fi

# --- 28. 命令 frontmatter 必须含 name（Qoder 插件规范要求 name+description 必填；
#         Claude Code 只读 description、忽略多余字段，故 name 双端安全） ---
cmdbad=""
for cf in "$PLUGIN_ROOT"/commands/*.md; do
  [ -e "$cf" ] || continue
  if ! awk '/^---$/{n++; next} n==1' "$cf" | grep -q '^name:'; then
    cmdbad="$cmdbad $(basename "$cf")"
  fi
done
if [ -n "$cmdbad" ]; then
  err "命令缺 name 字段（Qoder 兼容必需）:$cmdbad"
else
  ok "命令 frontmatter 均含 name（Qoder/Claude Code 双端兼容）"
fi

# --- 29. mccl-tester 自动重试规程齐（warm reset特征字/15分钟间隔/5次上限/重试日志/共用额度）---
tf="$PLUGIN_ROOT/agents/mccl-tester.md"
if [ ! -f "$tf" ]; then
  err "$tf 缺失"
else
  fail29=0
  for kw in "MX_EVENTTYPE_DRIVER" "mcErrorDriverWarmReset" "15分钟" "5次" "retry-" "不中断整轮" "禁止重启远程节点"; do
    grep -q -- "$kw" "$tf" || { err "$tf 未提及 $kw（自动重试规程不完整）"; fail29=1; }
  done
  # 边界守卫：hang与warm reset必须共用同一份场景额度（防两条规程各自计数出现至多12次执行），
  # 且重试不得与"禁止重启"冲突
  grep -q "共用" "$tf" || { err "$tf 未声明hang与warm reset共用重试额度"; fail29=1; }
  [ "$fail29" = "1" ] || ok "mccl-tester 自动重试规程齐（特征/间隔/次数/重试日志/共用额度/禁重启）"
fi

# --- 30. 执行摘要六字段齐（/mccl-test 下发即输出 + tester 落盘 preflight 首部）---
sum_bad=""
for f in "$PLUGIN_ROOT/commands/mccl-test.md" "$PLUGIN_ROOT/agents/mccl-tester.md"; do
  if [ ! -f "$f" ]; then
    err "$f 缺失"; sum_bad="$sum_bad $(basename "$f")缺失"; continue
  fi
  for kw in "执行摘要" "执行时间" "前置分发" "测试规模" "产物目录" "MD5基准" "测试命令"; do
    grep -q -- "$kw" "$f" || { err "$f 未提及 $kw（执行摘要六字段不完整）"; sum_bad="$sum_bad $(basename "$f"):$kw"; }
  done
done
[ -n "$sum_bad" ] || ok "执行摘要六字段齐（mccl-test 下发即输出 + mccl-tester preflight 首部）"

# --- 31. 定时任务占用清理链路闭合（scheduler 传 --free-occupied；safety 第9条含例外；
#         prober agent 声明自己不用该例外；gpu-probe 有 kill 审计字段）---
fail31=0
grep -q -- '--free-occupied' "$PLUGIN_ROOT/bin/mccl-queue-scheduler" \
  || { err "mccl-queue-scheduler 未传 --free-occupied（定时任务遇占用仍无限 WAIT）"; fail31=1; }
for kw in "--free-occupied" "例外" "occupancy.killed"; do
  grep -q -- "$kw" "$PLUGIN_ROOT/references/mccl-safety.md" \
    || { err "mccl-safety.md 未提及 $kw（占用清理例外未受约束）"; fail31=1; }
done
grep -q -- '--free-occupied' "$PLUGIN_ROOT/agents/mccl-prober.md" \
  || { err "mccl-prober agent 未声明 --free-occupied 例外归属（防 prober 越权杀进程）"; fail31=1; }
grep -q -- 'V_KILLS_JSON' "$PLUGIN_ROOT/bin/mccl-gpu-probe" \
  || { err "mccl-gpu-probe 缺 kill 审计字段（occupancy.killed）"; fail31=1; }
[ "$fail31" = "1" ] || ok "定时任务占用清理链路闭合（scheduler传参/safety例外/prober只读/kill审计）"

# --- 32. hang自动重试链路闭合（tester 采证->终止->重试；safety 第3条含终止/重试例外且禁重启；
#         README FAQ 两行同步；bench-runner 声明不沿用tester的hang重试）---
fail32=0
tf32="$PLUGIN_ROOT/agents/mccl-tester.md"
for kw in "采证" "kill -15" "kill -9" "再次hang" "追加" "PID≤1"; do
  grep -q -- "$kw" "$tf32" || { err "$tf32 未提及 $kw（hang重试规程不完整）"; fail32=1; }
done
for kw in "终止" "重试" "15分钟" "禁止重启远程节点"; do
  grep -q -- "$kw" "$PLUGIN_ROOT/references/mccl-safety.md" \
    || { err "mccl-safety.md 第3条未提及 $kw（hang终止/重试例外未受约束）"; fail32=1; }
done
for kw in "15分钟间隔重试" "共用同场景额度"; do
  grep -q -- "$kw" "$REPO_ROOT/README.md" \
    || { err "README FAQ 未提及 $kw（hang重试口径未同步）"; fail32=1; }
done
grep -q "不采用" "$PLUGIN_ROOT/agents/mccl-bench-runner.md" \
  || { err "mccl-bench-runner 未声明不沿用tester的hang重试（防两套规程混淆）"; fail32=1; }
[ "$fail32" = "1" ] || ok "hang自动重试链路闭合（tester采证终止重试/safety例外/README同步/bench边界）"

# --- 33. 数据对比产物生成器（xlsx+html）存在可用，且不经 reporter（无Bash隔离不动）---
xlsx_stats="$PLUGIN_ROOT/bin/mccl-data-report.py"
fail33=0
if [ ! -f "$xlsx_stats" ]; then
  err "$xlsx_stats 缺失"; fail33=1
elif [ ! -x "$xlsx_stats" ]; then
  err "$xlsx_stats 不可执行"; fail33=1
else
  help_out=$("$xlsx_stats" --help 2>&1); help_rc=$?
  [ "$help_rc" -eq 0 ] || { err "$xlsx_stats --help 退出码非 0 ($help_rc)"; fail33=1; }
  for kw in --run-dir --asym --sym --out --html-out; do
    echo "$help_out" | grep -q -- "$kw" || { err "$xlsx_stats --help 未提及 $kw"; fail33=1; }
  done
  # 不引用 MCCL_ 环境变量（保持不变式7的 env 引用闭合；日志路径由调用方传参）
  if grep -qE '\$\{?MCCL_[A-Z0-9_]+' "$xlsx_stats"; then
    err "$xlsx_stats 引用了 MCCL_ 环境变量（应纯参数传入）"; fail33=1
  fi
  # /mccl-test 编排里必须有生成数据对比产物的步骤，且两份产物路径都落在 run 目录
  grep -q "mccl-data-report.py" "$PLUGIN_ROOT/commands/mccl-test.md" \
    || { err "commands/mccl-test.md 未接入 mccl-data-report.py"; fail33=1; }
  grep -q "测试数据对比.xlsx" "$PLUGIN_ROOT/commands/mccl-test.md" \
    || { err "commands/mccl-test.md 未写明产物 测试数据对比.xlsx"; fail33=1; }
  grep -q "测试报告.html" "$PLUGIN_ROOT/commands/mccl-test.md" \
    || { err "commands/mccl-test.md 未写明产物 测试报告.html"; fail33=1; }
fi
[ "$fail33" = "1" ] || ok "数据对比产物生成器可用（xlsx+html、--run-dir/--asym/--sym/--out/--html-out、无MCCL_依赖、已接入/mccl-test）"

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有失败项"
exit "$fail"
