#!/usr/bin/env bash
# MCCL数字员工工具包自检。每次commit前跑：bash tests/check.sh
# 只验证静态不变式。agent的实际行为需拷入真实仓库后验证。
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "ok:   $*"; }

# --- 1. 测试.md 从未进入 git 历史 ---
if git log --all --pretty=format: --name-only 2>/dev/null | grep -qx '测试.md'; then
  err "测试.md 出现在 git 历史中（不可逆，需 filter-branch 清理）"
else
  ok "测试.md 不在 git 历史中"
fi

# --- 2. 测试.md 当前被忽略 ---
if git check-ignore -q 测试.md 2>/dev/null; then
  ok "测试.md 被 .gitignore 拦截"
elif [ -e 测试.md ]; then
  err "测试.md 存在但未被忽略"
else
  ok "测试.md 不存在于工作区"
fi

# --- 3. 已跟踪文件不得含私网IP字面量 ---
ip_hits=$(git ls-files -z | xargs -0 grep -lE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' 2>/dev/null || true)
if [ -n "$ip_hits" ]; then
  err "已跟踪文件含私网IP：$ip_hits"
else
  ok "已跟踪文件无私网IP字面量"
fi

# --- 4. mccl-env.sh 不得被跟踪 ---
if git ls-files --error-unmatch mccl-env.sh >/dev/null 2>&1; then
  err "mccl-env.sh 被跟踪（含内网信息，应只提交 .example）"
else
  ok "mccl-env.sh 未被跟踪"
fi

# --- 5. settings.json 合法且含关键 deny 规则 ---
if [ ! -f .claude/settings.json ]; then
  err ".claude/settings.json 缺失"
elif ! python3 -c 'import json,sys; json.load(open(".claude/settings.json"))' 2>/dev/null; then
  err ".claude/settings.json 不是合法JSON"
else
  missing=$(python3 - <<'PY'
import json
need = {"Bash(git push:*)", "Bash(reboot:*)", "Bash(shutdown:*)"}
have = set(json.load(open(".claude/settings.json")).get("permissions", {}).get("deny", []))
print(" ".join(sorted(need - have)))
PY
)
  if [ -n "$missing" ]; then
    err "settings.json 缺少 deny 规则：$missing"
  else
    ok "settings.json 合法且含关键 deny 规则"
  fi
fi

# --- 6. agent frontmatter 完整 ---
for f in .claude/agents/*.md; do
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
for v in $(grep -rhoE '\$\{?MCCL_[A-Z0-9_]+' .claude/ references/ 2>/dev/null \
           | sed 's/[${]//g' | sort -u); do
  grep -q "^export ${v}=" mccl-env.sh.example || undef="$undef $v"
done
if [ -n "$undef" ]; then
  err "引用了未在 mccl-env.sh.example 中定义的变量：$undef"
else
  ok "环境变量引用闭合"
fi

# --- 8. mccl-reporter 不得拥有 Bash（防报告造假的物理隔离）---
rf=".claude/agents/mccl-reporter.md"
if [ ! -f "$rf" ]; then
  err "$rf 缺失"
elif awk '/^---$/{n++; next} n==1' "$rf" | sed -n 's/^tools: *//p' | grep -qw 'Bash'; then
  err "$rf 的 tools 含 Bash——报告工程师必须无执行能力"
else
  ok "mccl-reporter 无 Bash"
fi

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "有失败项"
exit "$fail"
