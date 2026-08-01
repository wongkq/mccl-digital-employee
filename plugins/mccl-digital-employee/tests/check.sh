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
  # loader --keys 对 example 跑一次，拿到全部变量名（raw 14 + derived 7）
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

# --- 9. 编排命令引用的 agent 均已定义 ---
cf="$PLUGIN_ROOT/commands/mccl-run.md"
if [ ! -f "$cf" ]; then
  err "$cf 缺失"
else
  for a in mccl-developer mccl-tester mccl-reporter mccl-supervisor; do
    grep -q "$a" "$cf" || err "$cf 未引用 agent: $a"
    [ -f "$PLUGIN_ROOT/agents/$a.md" ] || err "agent 定义缺失: $PLUGIN_ROOT/agents/$a.md"
  done
  ok "编排命令引用的 agent 均已定义"
fi

# --- 10. checklist 三份齐全 ---
for s in dev test report bench; do
  [ -f "$PLUGIN_ROOT/references/supervisor-checklists/$s.md" ] || err "checklist 缺失: $s.md"
done
ok "supervisor checklist 齐全"

# --- 11. bin/mccl-toolkit-root 存在、可执行，且自举校验通过 ---
tk="$PLUGIN_ROOT/bin/mccl-toolkit-root"
if [ ! -f "$tk" ]; then
  err "$tk 缺失"
elif [ ! -x "$tk" ]; then
  err "$tk 不可执行"
else
  # 显式unset CLAUDE_PLUGIN_ROOT，强制走BASH_SOURCE反推兜底路径；
  # 从插件根本身跑，期望输出就是插件根——验证两种装法里"项目内拷贝"那种（不依赖$CLAUDE_PLUGIN_ROOT）确实成立。
  out="$(cd "$PLUGIN_ROOT" && env -u CLAUDE_PLUGIN_ROOT "$tk" 2>/dev/null)"
  if [ "$out" = "$PLUGIN_ROOT" ]; then
    ok "bin/mccl-toolkit-root 自举校验通过（输出=$out）"
  else
    err "bin/mccl-toolkit-root 自举校验失败：期望 $PLUGIN_ROOT，实得 '$out'"
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
    for kw in --mode --hosts --reuse-bw; do
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

# --- 17. /mccl-bench 命令引用的 agent 均已定义 ---
bcf="$PLUGIN_ROOT/commands/mccl-bench.md"
if [ ! -f "$bcf" ]; then
  err "$bcf 缺失"
else
  for a in mccl-bench-planner mccl-bench-runner mccl-developer mccl-reporter mccl-supervisor mccl-prober; do
    grep -q "$a" "$bcf" || err "$bcf 未引用 agent: $a"
    [ -f "$PLUGIN_ROOT/agents/$a.md" ] || err "agent 定义缺失: $a.md"
  done
  ok "/mccl-bench 引用的 agent 均已定义"
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

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有失败项"
exit "$fail"
