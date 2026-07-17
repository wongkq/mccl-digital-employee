#!/usr/bin/env bash
# MCCL数字员工工具包自检。每次commit前跑：bash plugins/mccl-digital-employee/tests/check.sh
# 只验证静态不变式。agent的实际行为需拷入真实仓库后验证。
#
# 双根：仓库级检查（#1-5）用 REPO_ROOT（git仓库根，测试.md/mccl-env.sh/settings.json所在处）；
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

# --- 4. mccl-env.sh 不得被跟踪 ---
if git -C "$REPO_ROOT" ls-files --error-unmatch mccl-env.sh >/dev/null 2>&1; then
  err "mccl-env.sh 被跟踪（含内网信息，应只提交 .example）"
else
  ok "mccl-env.sh 未被跟踪"
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

# --- 7. agent 引用的 MCCL_ 变量都在 mccl-env.sh.example 中定义 ---
undef=""
for v in $(grep -rhoE '\$\{?MCCL_[A-Z0-9_]+' "$PLUGIN_ROOT/agents/" "$PLUGIN_ROOT/commands/" "$PLUGIN_ROOT/references/" "$PLUGIN_ROOT/bin/" 2>/dev/null \
           | sed 's/[${]//g' | sort -u); do
  grep -q "^export ${v}=" "$PLUGIN_ROOT/mccl-env.sh.example" || undef="$undef $v"
done
if [ -n "$undef" ]; then
  err "引用了未在 mccl-env.sh.example 中定义的变量：$undef"
else
  ok "环境变量引用闭合"
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
for s in dev test report; do
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

# --- 12. mccl-env.sh.example 里节点派生量确实从 $MCCL_NODES 派生，不是写死的值 ---
example="$PLUGIN_ROOT/mccl-env.sh.example"
if [ ! -f "$example" ]; then
  err "$example 缺失"
else
  # 每个派生量必须引用的上游变量：MCCL_NP 是从 MCCL_NNODES 算出来的（间接派生自
  # MCCL_NODES），其余三个直接引用 MCCL_NODES。
  derive_bad=""
  check_derive() {
    v="$1"; upstream="$2"
    line=$(grep "^export ${v}=" "$example" || true)
    if [ -z "$line" ]; then
      derive_bad="$derive_bad ${v}(未定义)"
    elif ! echo "$line" | grep -q "$upstream"; then
      derive_bad="$derive_bad ${v}(未引用\$${upstream}，疑似写死)"
    fi
  }
  check_derive MCCL_NODE0_IP MCCL_NODES
  check_derive MCCL_NNODES MCCL_NODES
  check_derive MCCL_NP MCCL_NNODES
  check_derive MCCL_HOST_SPEC MCCL_NODES
  if [ -n "$derive_bad" ]; then
    err "mccl-env.sh.example 节点派生量有问题：$derive_bad"
  else
    ok "mccl-env.sh.example 节点派生量（NODE0_IP/NNODES/NP/HOST_SPEC）均从\$MCCL_NODES派生"
  fi
fi

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有失败项"
exit "$fail"
