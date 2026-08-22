#!/usr/bin/env bash
# tests/test-data-report.sh - bin/mccl-data-report.py 的本地验证（xlsx + html 两份产物）。
# 喂净化过的 mock 日志（nccl-tests 输出格式，不含真实IP），生成产物后解包/解析断言：
# 只含实际测试的尺寸、计算列数值正确、重试日志选择、缺场景留空、无数据不产文件。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
STATS="$PLUGIN_ROOT/bin/mccl-data-report.py"

pass=0; fail=0
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok:   $1"; pass=$((pass+1));
  else echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}
assert_contains() { # <desc> <haystack-file|string> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok:   $1"; pass=$((pass+1));
  else echo "FAIL: $1 (未找到 [$3])" >&2; fail=$((fail+1)); fi
}
assert_not_contains() { # <desc> <haystack-file|string> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL: $1 (不应出现 [$3])" >&2; fail=$((fail+1));
  else echo "ok:   $1"; pass=$((pass+1)); fi
}
[ -f "$STATS" ] || { echo "FAIL: $STATS 不存在" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---- 造 mock 日志的辅助函数（nccl-tests 数据行格式）----
# 参数：输出文件；之后每行参数为 "size oop_time oop_busbw ip_time ip_busbw"
mklog() {
  local out="$1"; shift
  cat > "$out" <<'HDR'
# nccl-tests version 2.17.6
# Collective test starting: all_reduce_perf
# nThread 1 nGpus 1 minBytes 32768 maxBytes 33554432 step: 2(factor) warmup iters: 200 iters: 20000
#
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)             (us)  (GB/s)  (GB/s)
HDR
  local row size ot ob it ib
  for row in "$@"; do
    set -- $row; size=$1; ot=$2; ob=$3; it=$4; ib=$5
    printf '%13d %13d     float     sum      -1 %8s %7s %7s %7d %8s %7s %7s %7d\n' \
      "$size" $((size/4)) "$ot" "$(python3 -c "print(round($size/$ot/1e3,2))")" "$ob" 0 \
      "$it" "$(python3 -c "print(round($size/$it/1e3,2))")" "$ib" 0 >> "$out"
  done
}

# 读 xlsx 的 sheet1.xml 全文本（inlineStr + 数值都在里面）与单元格字典
sheet_text() { # <xlsx>
  python3 - "$1" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
sys.stdout.write(z.read('xl/worksheets/sheet1.xml').decode('utf-8'))
PY
}
cell_val() { # <xlsx> <ref>
  python3 - "$1" "$2" <<'PY'
import sys, zipfile, xml.etree.ElementTree as ET
ns = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
root = ET.fromstring(zipfile.ZipFile(sys.argv[1]).read('xl/worksheets/sheet1.xml'))
for c in root.iter('{%s}c' % ns['m']):
    if c.get('r') == sys.argv[2]:
        t = c.find('m:is/m:t', ns); v = c.find('m:v', ns)
        sys.stdout.write(t.text if t is not None else (v.text if v is not None else ''))
        break
PY
}
xml_ok() { # <xlsx>  良构性校验
  python3 - "$1" <<'PY'
import sys, zipfile, xml.etree.ElementTree as ET
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith('.xml') or n.endswith('.rels'):
        ET.fromstring(z.read(n))
PY
}
html_text() { # <html>
  cat -- "$1"
}
raw_json() { # <html>  提取 const raw = [...]; 的 JSON 数组文本
  python3 - "$1" <<'PY'
import sys, re
html = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'const raw = (\[.*?\]);', html, re.S)
sys.stdout.write(m.group(1) if m else '')
PY
}
raw_cell() { # <html> <row> <col>  raw[row][col]（0起）
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re, json
html = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'const raw = (\[.*?\]);', html, re.S)
raw = json.loads(m.group(1))
v = raw[int(sys.argv[2])][int(sys.argv[3])]
sys.stdout.write('null' if v is None else str(v))
PY
}

# =====================================================================
# --- 1. 双场景（32K-16M 共10档）：生成成功、只含实测尺寸、数值正确 ---
# =====================================================================
mkdir -p "$TMP/run1"
mklog "$TMP/run1/test-asymmetric.log" \
  "32768 45.99 1.38 45.91 1.38" \
  "65536 56.86 2.23 56.86 2.23" \
  "16777216 371.72 87.45 371.69 87.45"
mklog "$TMP/run1/test-symmetric.log" \
  "32768 45.50 1.38 45.45 1.38" \
  "65536 55.90 2.23 55.80 2.23" \
  "16777216 370.00 87.45 369.90 87.46"
python3 "$STATS" --run-dir "$TMP/run1" > "$TMP/run1.out" 2>&1
rc=$?
assert_eq "用例1 退出码0" "0" "$rc"
XLSX="$TMP/run1/测试数据对比.xlsx"
[ -f "$XLSX" ] && echo "ok:   用例1 产物存在" && pass=$((pass+1)) || { echo "FAIL: 用例1 产物不存在" >&2; fail=$((fail+1)); }
xml_ok "$XLSX"; assert_eq "用例1 XML良构" "0" "$?"
TXT=$(sheet_text "$XLSX")
assert_contains "用例1 含32KB行" "$TXT" ">32KB<"
assert_contains "用例1 含16MB行" "$TXT" ">16MB<"
assert_not_contains "用例1 不含1KB（未测试）" "$TXT" ">1KB<"
assert_not_contains "用例1 不含2KB（未测试）" "$TXT" ">2KB<"
assert_not_contains "用例1 不含32MB（未测试）" "$TXT" ">32MB<"
assert_eq "用例1 asym时延(oop)" "45.99" "$(cell_val "$XLSX" B5)"
assert_eq "用例1 sym时延(oop)" "45.5" "$(cell_val "$XLSX" C5)"
assert_eq "用例1 asym带宽(oop,busbw)" "1.38" "$(cell_val "$XLSX" E5)"
assert_eq "用例1 sym带宽(ip,busbw)" "1.38" "$(cell_val "$XLSX" L5)"
# 时延降低% = (45.99-45.50)/45.99*100 = 1.07
assert_eq "用例1 时延降低%(oop)" "1.07" "$(cell_val "$XLSX" D5)"
# 带宽提升% = (1.38-1.38)/1.38*100 = 0
assert_eq "用例1 带宽提升%(oop,=0)" "0" "$(cell_val "$XLSX" G5)"
assert_contains "用例1 表尾注明数据来源asym" "$TXT" "数据来源：非对称内存=test-asymmetric.log"
assert_contains "用例1 表尾注明数据来源sym" "$TXT" "对称内存=test-symmetric.log"
assert_contains "用例1 模板公式说明行" "$TXT" "时延降低(%) = (非对称内存时延 - 对称内存时延) / 非对称内存时延 × 100%"
assert_contains "用例1 带宽提升公式说明行" "$TXT" "带宽提升(%) = (对称内存带宽 - 非对称内存带宽) / 非对称内存带宽 × 100%"
# HTML 侧（同一次调用产出，数字须与 xlsx 一致）
HTML="$TMP/run1/测试报告.html"
[ -f "$HTML" ] && echo "ok:   用例1 html产物存在" && pass=$((pass+1)) || { echo "FAIL: 用例1 html产物不存在" >&2; fail=$((fail+1)); }
HTXT=$(html_text "$HTML")
assert_contains "用例1 html副标题实际范围" "$HTXT" "数据大小 32KB ~ 16MB"
assert_not_contains "用例1 html不含1KB（未测试）" "$HTXT" '"1KB"'
assert_not_contains "用例1 html不含32MB（未测试）" "$HTXT" '"32MB"'
assert_eq "用例1 html raw行数=实测档数" "3" "$(raw_json "$HTML" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "用例1 html raw[0]标签" "32KB" "$(raw_cell "$HTML" 0 0)"
assert_eq "用例1 html raw[0] asym时延(oop)" "45.99" "$(raw_cell "$HTML" 0 1)"
assert_eq "用例1 html raw[0] sym时延(oop)" "45.5" "$(raw_cell "$HTML" 0 2)"
assert_eq "用例1 html raw[0] 时延降低%(oop)" "1.07" "$(raw_cell "$HTML" 0 3)"
assert_eq "用例1 html raw[0] sym带宽(ip)" "1.38" "$(raw_cell "$HTML" 0 11)"
assert_contains "用例1 html公式-非对称内存带宽" "$HTXT" "/ 非对称内存带宽 × 100%"
assert_not_contains "用例1 html公式-不含FC带宽" "$HTXT" "FC带宽"
assert_contains "用例1 html来源注记asym" "$HTXT" "数据来源：非对称内存=test-asymmetric.log"
assert_contains "用例1 html来源注记sym" "$HTXT" "对称内存=test-symmetric.log"
assert_contains "用例1 html总结段-档数" "$HTXT" "共3档"

# =====================================================================
# --- 2. run-dir 重试选择：有 retry-<k> 取最大 k ---
# =====================================================================
mkdir -p "$TMP/run2"
cp "$TMP/run1/test-asymmetric.log" "$TMP/run2/test-asymmetric.log"
mklog "$TMP/run2/test-symmetric.log"        "32768 45.50 1.38 45.45 1.38"
mklog "$TMP/run2/test-symmetric.retry-1.log" "32768 50.50 1.38 50.45 1.38"
mklog "$TMP/run2/test-symmetric.retry-2.log" "32768 55.50 1.38 55.45 1.38"
python3 "$STATS" --run-dir "$TMP/run2" > "$TMP/run2.out" 2>&1
assert_eq "用例2 退出码0" "0" "$?"
XLSX2="$TMP/run2/测试数据对比.xlsx"
assert_eq "用例2 取retry-2的sym时延" "55.5" "$(cell_val "$XLSX2" C5)"
assert_eq "用例2 取retry-2的sym时延(ip)" "55.45" "$(cell_val "$XLSX2" I5)"
assert_contains "用例2 来源注记retry-2" "$(sheet_text "$XLSX2")" "test-symmetric.retry-2.log"
assert_not_contains "用例2 不误用首次日志" "$(sheet_text "$XLSX2")" "对称内存=test-symmetric.log。"
assert_contains "用例2 html来源注记retry-2" "$(html_text "$TMP/run2/测试报告.html")" "test-symmetric.retry-2.log"
assert_eq "用例2 html取retry-2的sym时延" "55.5" "$(raw_cell "$TMP/run2/测试报告.html" 0 2)"

# =====================================================================
# --- 3. 缺 sym 日志：仍生成，sym 侧空白 + 缺失说明 ---
# =====================================================================
mkdir -p "$TMP/run3"
cp "$TMP/run1/test-asymmetric.log" "$TMP/run3/test-asymmetric.log"
python3 "$STATS" --run-dir "$TMP/run3" > "$TMP/run3.out" 2>&1
assert_eq "用例3 退出码0" "0" "$?"
XLSX3="$TMP/run3/测试数据对比.xlsx"
assert_eq "用例3 asym列照常填充" "45.99" "$(cell_val "$XLSX3" B5)"
assert_eq "用例3 sym时延列空白" "" "$(cell_val "$XLSX3" C5)"
assert_eq "用例3 时延降低%空白" "" "$(cell_val "$XLSX3" D5)"
assert_contains "用例3 缺失说明" "$(sheet_text "$XLSX3")" "场景B（对称内存）日志缺失"
# HTML 侧：sym 数值为 null（图表断点），总结段如实说明缺失
assert_eq "用例3 html raw[0] sym时延为null" "null" "$(raw_cell "$TMP/run3/测试报告.html" 0 2)"
assert_eq "用例3 html raw[0] %为null" "null" "$(raw_cell "$TMP/run3/测试报告.html" 0 3)"
assert_eq "用例3 html raw[0] asym时延照常" "45.99" "$(raw_cell "$TMP/run3/测试报告.html" 0 1)"
assert_contains "用例3 html总结段说明缺失" "$(html_text "$TMP/run3/测试报告.html")" "场景B（对称内存）日志缺失"

# =====================================================================
# --- 4. 尺寸不对齐：asym 32K起，sym 只有 32M 之外的 1M 起 ---
# =====================================================================
mkdir -p "$TMP/run4"
mklog "$TMP/run4/test-asymmetric.log" \
  "32768 45.99 1.38 45.91 1.38" \
  "1048576 85.89 23.65 85.83 23.67"
mklog "$TMP/run4/test-symmetric.log" \
  "1048576 85.00 23.67 84.90 23.67"
python3 "$STATS" --run-dir "$TMP/run4" > "$TMP/run4.out" 2>&1
assert_eq "用例4 退出码0" "0" "$?"
XLSX4="$TMP/run4/测试数据对比.xlsx"
TXT4=$(sheet_text "$XLSX4")
assert_contains "用例4 含32KB行（asym有）" "$TXT4" ">32KB<"
assert_eq "用例4 32KB行sym时延空白" "" "$(cell_val "$XLSX4" C5)"
assert_eq "用例4 32KB行%空白" "" "$(cell_val "$XLSX4" D5)"
assert_eq "用例4 1MB行两侧齐全(asym)" "85.89" "$(cell_val "$XLSX4" B6)"
assert_eq "用例4 1MB行两侧齐全(sym)" "85" "$(cell_val "$XLSX4" C6)"

# =====================================================================
# --- 5. 两日志全缺：退出码 3，不产文件 ---
# =====================================================================
mkdir -p "$TMP/run5"
python3 "$STATS" --run-dir "$TMP/run5" > "$TMP/run5.out" 2>&1
assert_eq "用例5 无数据退出码3" "3" "$?"
[ ! -e "$TMP/run5/测试数据对比.xlsx" ] && echo "ok:   用例5 未产xlsx" && pass=$((pass+1)) \
  || { echo "FAIL: 用例5 不应产xlsx" >&2; fail=$((fail+1)); }
[ ! -e "$TMP/run5/测试报告.html" ] && echo "ok:   用例5 未产html" && pass=$((pass+1)) \
  || { echo "FAIL: 用例5 不应产html" >&2; fail=$((fail+1)); }
# 只有空日志（测试没跑起来）同 3
mkdir -p "$TMP/run5b"
mklog "$TMP/run5b/test-asymmetric.log"
python3 "$STATS" --run-dir "$TMP/run5b" > /dev/null 2>&1
assert_eq "用例5b 空日志退出码3" "3" "$?"

# =====================================================================
# --- 6. 正绿负红样式与显式 --asym/--sym 模式 ---
# =====================================================================
python3 "$STATS" --asym "$TMP/run1/test-asymmetric.log" --sym "$TMP/run1/test-symmetric.log" \
  --out "$TMP/run6.xlsx" > /dev/null 2>&1
assert_eq "用例6 显式模式退出码0" "0" "$?"
python3 - "$TMP/run6.xlsx" <<'PY' > "$TMP/run6.cells"
import sys, zipfile, xml.etree.ElementTree as ET
ns = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
root = ET.fromstring(zipfile.ZipFile(sys.argv[1]).read('xl/worksheets/sheet1.xml'))
for c in root.iter('{%s}c' % ns['m']):
    v = c.find('m:v', ns)
    if v is not None:
        print('%s s=%s v=%s' % (c.get('r'), c.get('s'), v.text))
PY
# run1 16MB: lat% = (371.72-370.00)/371.72*100 = 0.46（正数，样式 s=5 绿底）
assert_contains "用例6 正%绿底样式(s5)" "$(cat "$TMP/run6.cells")" "D7 s=5 v=0.46"
# run1 32K: bw% = (1.38-1.38)/1.38*100 = 0（0，样式 s=6 无底色）
assert_contains "用例6 零%无底色样式(s6)" "$(cat "$TMP/run6.cells")" "G5 s=6 v=0"
# 造一个负%场景：sym 时延比 asym 长
mklog "$TMP/run6-asym.log" "32768 40.00 1.38 40.00 1.38"
mklog "$TMP/run6-sym.log"  "32768 50.00 1.38 50.00 1.38"
python3 "$STATS" --asym "$TMP/run6-asym.log" --sym "$TMP/run6-sym.log" \
  --out "$TMP/run6b.xlsx" --html-out "$TMP/run6b.html" > /dev/null 2>&1
python3 - "$TMP/run6b.xlsx" <<'PY' > "$TMP/run6b.cells"
import sys, zipfile, xml.etree.ElementTree as ET
ns = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
root = ET.fromstring(zipfile.ZipFile(sys.argv[1]).read('xl/worksheets/sheet1.xml'))
for c in root.iter('{%s}c' % ns['m']):
    v = c.find('m:v', ns)
    if v is not None:
        print('%s s=%s v=%s' % (c.get('r'), c.get('s'), v.text))
PY
# lat% = (40-50)/40*100 = -25（负数，样式 s=7 粉底）
assert_contains "用例6b 负%粉底样式(s7)" "$(cat "$TMP/run6b.cells")" "D5 s=7 v=-25"
# 样式表复刻模板配色：表头蓝底白字、正%绿底、负%粉底、%列 0.00"%" 数字格式、宋体
STYLES=$(python3 - "$TMP/run6.xlsx" <<'PY'
import sys, zipfile
sys.stdout.write(zipfile.ZipFile(sys.argv[1]).read('xl/styles.xml').decode('utf-8'))
PY
)
assert_contains "样式表-表头蓝底FF4472C4" "$STYLES" 'rgb="FF4472C4"'
assert_contains "样式表-正%绿底FFC6EFCE" "$STYLES" 'rgb="FFC6EFCE"'
assert_contains "样式表-负%粉底FFFFC7CE" "$STYLES" 'rgb="FFFFC7CE"'
assert_contains "样式表-表头白字FFFFFFFF" "$STYLES" 'rgb="FFFFFFFF"'
assert_contains "样式表-%列数字格式0.00%" "$STYLES" 'formatCode="0.00&quot;%&quot;"'
assert_contains "样式表-宋体" "$STYLES" 'val="宋体"'

# =====================================================================
# --- 7. HTML 结构复刻模板（四张图卡/CDN/图表JS）与总结段数字正确性 ---
# =====================================================================
# 用例6 显式模式也会在 --out 同目录产 html
[ -f "$TMP/测试报告.html" ] && echo "ok:   用例7 显式模式html默认路径" && pass=$((pass+1)) \
  || { echo "FAIL: 用例7 显式模式未产html（默认应在--out同目录）" >&2; fail=$((fail+1)); }
HT7=$(html_text "$TMP/测试报告.html")
for kw in 'canvas id="latencyChart"' 'canvas id="bwChart"' 'canvas id="latPctChart"' 'canvas id="bwPctChart"' \
          'chart.js@4.4.1/dist/chart.umd.min.js' '时延对比（越低越好）' '带宽对比（越高越好）' \
          '时延降低百分比' '带宽提升百分比'; do
  assert_contains "用例7 html含模板元素[$kw]" "$HT7" "$kw"
done
# 总结段数字正确性：run1 的 3 档（32K/64K/16M），OOP时延 sym 全更低（3/3），
# 时延降低最显著 64KB=1.69%，最差 16MB=0.46%（(371.72-370)/371.72*100=0.4627→0.46）
assert_contains "用例7 总结-时延更优计数" "$HT7" "3/3档尺寸对称内存更低"
assert_contains "用例7 总结-时延降低最显著" "$HT7" "1.69%（64KB）"
assert_contains "用例7 总结-时延降低最差" "$HT7" "0.46%（16MB）"
# 尺寸不对齐场景（用例4）：总结段须写明单侧缺失档数（3档中仅1档可比）
HT4=$(html_text "$TMP/run4/测试报告.html")
assert_contains "用例7 总结-单侧缺失说明" "$HT4" "1档两侧数据齐全可对比"
assert_contains "用例7 总结-其余缺失" "$HT4" "其余1档单侧缺失未参与对比"

# =====================================================================
echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
