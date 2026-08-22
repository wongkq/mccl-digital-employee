#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MCCL 测试数据对比产物生成器（Excel 对比表 + HTML 图表报告）。

读场景A（非对称内存）/场景B（对称内存）的原始 mpirun 日志（nccl-tests 风格输出），
一次调用同时产出两份对比产物（同一份选定的日志，来源一致）：

1. `测试数据对比.xlsx`--按《测试数据对比模版.xlsx》的版式：Out-of-place（输出）与
   In-place（输入）两大块，各含 非对称内存/对称内存 的时延(us)、带宽(GB/s，busbw
   口径) 与计算列 时延降低(%)、带宽提升(%)。
2. `测试报告.html`--按《测试报告模版.html》的版式：Chart.js 折线图（时延对比、
   带宽对比、时延降低%、带宽提升%）+ 程序化生成的数据总结段 + 公式说明。

关键约束（与需求逐条对应）：
- **只统计日志里实际出现的消息尺寸**（如 32K-32M），未测试的 1K/2K 等不出现。
- 时延降低(%) = (非对称时延 - 对称时延) / 非对称时延 × 100
- 带宽提升(%) = (对称带宽 - 非对称带宽) / 非对称带宽 × 100
- Excel：正数绿底(FFC6EFCE)、负数粉底(FFFFC7CE)、0 无底色（模板 s5/s6/s7 的
  背景填充色做法）；表头蓝底白字加粗。
- HTML 总结段从数据推导生成（档数、更优/更差计数、极值及其尺寸），不编造叙述；
  某场景缺失时如实写"对比未覆盖"。
- 纯标准库（zipfile + 手写 SpreadsheetML），不依赖 openpyxl--目标机器不一定装了它。
- 本脚本不引用任何 MCCL_* 环境变量（日志路径由调用方给定），保持 env 引用闭合。

用法：
  mccl-data-report.py --run-dir <dir> [--out <xlsx>] [--html-out <html>]   # 自动选各场景最终日志
  mccl-data-report.py --asym <log> --sym <log> --out <xlsx> [--html-out <html>]  # 显式指定（测试/手动）

--run-dir 模式下的日志选择规则：某场景存在 test-<场景>.retry-<k>.log 时取最大 k 的
那份（mccl-tester 规定"最终判定以最后一次执行为准"），否则用首次 test-<场景>.log；
两者皆无视为该场景缺失（对应列留空，表尾注明）。

退出码：0=生成成功；2=参数错误；3=没有任何可解析的 perf 数据（两份产物都不生成）。
"""
import argparse
import json
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape

# nccl-tests 风格数据行：
#   size count type redop root  oop_time oop_algbw oop_busbw oop_wrong  ip_time ip_algbw ip_busbw ip_wrong
# 例： 32768 8192 float sum -1 45.99 0.71 1.38 0 45.91 0.71 1.38 0
DATA_ROW_RE = re.compile(
    r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(-?\d+)\s+'
    r'([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+(\d+)\s+'
    r'([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+(\d+)\s*$'
)

# 模板的尺寸标签写法（1KB..64KB、128K..512K、1MB 起），复刻原样。
SIZE_LABELS = {
    1024: '1KB', 2048: '2KB', 4096: '4KB', 8192: '8KB', 16384: '16KB',
    32768: '32KB', 65536: '64KB',
    131072: '128K', 262144: '256K', 524288: '512K',
    1048576: '1MB', 2097152: '2MB', 4194304: '4MB', 8388608: '8MB',
    16777216: '16MB', 33554432: '32MB', 67108864: '64MB',
    134217728: '128MB', 268435456: '256MB', 536870912: '512MB',
    1073741824: '1GB', 2147483648: '2GB',
}


def size_label(n):
    """尺寸字节数 -> 模板风格标签。非标准幂次尺寸回退通用格式。"""
    if n in SIZE_LABELS:
        return SIZE_LABELS[n]
    if n >= 1048576:
        return '%gMB' % (n / 1048576.0)
    return '%gKB' % (n / 1024.0)


def parse_log(path):
    """解析一份 perf 日志。返回 {size: {'oop':(time_us,busbw), 'ip':(time_us,busbw), 'wrong':bool}}。"""
    rows = {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = DATA_ROW_RE.match(line)
            if not m:
                continue
            size = int(m.group(1))
            oop = (float(m.group(6)), float(m.group(8)))   # time(us), busbw(GB/s)
            ip = (float(m.group(10)), float(m.group(12)))
            wrong = int(m.group(9)) != 0 or int(m.group(13)) != 0
            rows[size] = {'oop': oop, 'ip': ip, 'wrong': wrong}
    return rows


def pick_final_log(run_dir, stem):
    """run 目录里选某场景最终判定的日志文件（有 retry 取最大 k，否则首次，无则 None）。"""
    retry_pat = re.compile(r'^test-%s\.retry-(\d+)\.log$' % re.escape(stem))
    best_k, best_name = None, None
    try:
        names = os.listdir(run_dir)
    except OSError:
        return None
    for name in names:
        m = retry_pat.match(name)
        if m:
            k = int(m.group(1))
            if best_k is None or k > best_k:
                best_k, best_name = k, name
    if best_name is not None:
        return os.path.join(run_dir, best_name)
    base = os.path.join(run_dir, 'test-%s.log' % stem)
    return base if os.path.isfile(base) else None


# ---------------------------------------------------------------------------
# xlsx 生成（纯手写 SpreadsheetML，字符串用 inlineStr 免 sharedStrings 记账）
# ---------------------------------------------------------------------------

# styles.xml 复刻模板配色：表头蓝底(FF4472C4)白字加粗；正数%绿底(FFC6EFCE)、
# 负数%粉底(FFFFC7CE)、0 无底色（模板 s5/s6/s7 的做法是**背景填充色**，不是字色）；
# % 列 numFmt 176 = '0.00"%"'（显示带 % 后缀）；字体宋体。
# cellXfs：0默认 1表头(行1-3) 2表头小字(行4) 3尺寸列 4数字 5%正(绿底) 6%零/空 7%负(粉底) 8说明粗体 9说明正文
STYLES_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="176" formatCode="0.00&quot;%&quot;"/></numFmts>'
    '<fonts count="4">'
    '<font><sz val="11"/><color rgb="FF000000"/><name val="宋体"/><charset val="134"/></font>'
    '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="宋体"/><charset val="134"/></font>'
    '<font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="宋体"/><charset val="134"/></font>'
    '<font><b/><sz val="11"/><color rgb="FF000000"/><name val="宋体"/><charset val="134"/></font>'
    '</fonts>'
    '<fills count="5">'
    '<fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FF4472C4"/><bgColor indexed="64"/></patternFill></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFC6EFCE"/><bgColor indexed="64"/></patternFill></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFFC7CE"/><bgColor indexed="64"/></patternFill></fill>'
    '</fills>'
    '<borders count="2">'
    '<border><left/><right/><top/><bottom/><diagonal/></border>'
    '<border>'
    '<left style="thin"><color auto="1"/></left><right style="thin"><color auto="1"/></right>'
    '<top style="thin"><color auto="1"/></top><bottom style="thin"><color auto="1"/></bottom>'
    '<diagonal/>'
    '</border>'
    '</borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="10">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="2" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="176" fontId="0" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="176" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="176" fontId="0" fillId="4" borderId="1" xfId="0" applyNumberFormat="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf>'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>'
)

CONTENT_TYPES_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '</Types>'
)

RELS_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>'
)

WORKBOOK_RELS_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>'
)

SHEET_NAME = '综合对比'


def workbook_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>' % escape(SHEET_NAME)
    )


def col_letter(idx):
    """1 -> A, 2 -> B, ..."""
    s = ''
    while idx > 0:
        idx, rem = divmod(idx - 1, 26)
        s = chr(ord('A') + rem) + s
    return s


def _num(v):
    """浮点数 -> 无精度噪声的 XML 数字文本（round 后 repr，如 45.99）。"""
    r = round(v, 2)
    if r == int(r):
        return str(int(r))
    return repr(r)


class Sheet(object):
    """逐格攒 sheet1.xml。行号从 1 计。"""

    def __init__(self):
        self.rows = {}   # row_num -> [(col_idx, xml)]
        self.heights = {}
        self.merges = []
        self.max_row = 0
        self.max_col = 0

    def cell(self, row, col, style, value=None, numeric=False):
        ref = '%s%d' % (col_letter(col), row)
        if numeric:
            xml = '<c r="%s" s="%d"><v>%s</v></c>' % (ref, style, _num(value))
        elif value is None:
            xml = '<c r="%s" s="%d"/>' % (ref, style)
        else:
            xml = '<c r="%s" s="%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (
                ref, style, escape(str(value)))
        self.rows.setdefault(row, []).append((col, xml))
        self.max_row = max(self.max_row, row)
        self.max_col = max(self.max_col, col)

    def merge(self, r1, c1, r2, c2):
        self.merges.append('%s%d:%s%d' % (col_letter(c1), r1, col_letter(c2), r2))

    def to_xml(self):
        out = [
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n',
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
            '<dimension ref="A1:%s%d"/>' % (col_letter(self.max_col or 1), self.max_row or 1),
            '<sheetViews><sheetView tabSelected="1" workbookViewId="0"/></sheetViews>',
            '<sheetFormatPr defaultColWidth="9" defaultRowHeight="14.25"/>',
        ]
        # 列宽复刻模板：A=12，(B,C)=14、D=12、(E,F)=14、G=12 …… 交替到 M
        widths = {1: 12, 2: 14, 3: 14, 4: 12, 5: 14, 6: 14, 7: 12, 8: 14, 9: 14,
                  10: 12, 11: 14, 12: 14, 13: 12}
        out.append('<cols>')
        for c in range(1, max(13, self.max_col) + 1):
            out.append('<col min="%d" max="%d" width="%d" customWidth="1"/>' % (c, c, widths.get(c, 12)))
        out.append('</cols>')
        out.append('<sheetData>')
        for r in sorted(self.rows):
            ht = ' ht="%s" customHeight="1"' % self.heights[r] if r in self.heights else ''
            out.append('<row r="%d"%s>' % (r, ht))
            for _, xml in sorted(self.rows[r]):
                out.append(xml)
            out.append('</row>')
        out.append('</sheetData>')
        if self.merges:
            out.append('<mergeCells count="%d">' % len(self.merges))
            for ref in self.merges:
                out.append('<mergeCell ref="%s"/>' % ref)
            out.append('</mergeCells>')
        out.append('</worksheet>')
        return ''.join(out)


def pct_style(v):
    """模板 s5/s6/s7 的做法：正数绿底(FFC6EFCE)、负数粉底(FFFFC7CE)、0 无底色。None -> 空（保留边框）。"""
    if v is None:
        return 6
    if v > 0:
        return 5
    if v < 0:
        return 7
    return 6


def compute_rows(asym, sym):
    """两场景日志实际尺寸的并集（升序），逐档计算两模式的所有数值。

    xlsx 与 html 两份产物共用这一份计算，保证同一次调用产出的数字完全一致。
    返回 [(size, label, {mode: (a_lat, s_lat, lat_pct, a_bw, s_bw, bw_pct)})]，
    mode in ('oop','ip')；缺失侧的值为 None，无法计算的百分比为 None。
    """
    rows = []
    for size in sorted(set(asym or {}) | set(sym or {})):
        entry = {}
        for mode in ('oop', 'ip'):
            a = (asym or {}).get(size)
            s = (sym or {}).get(size)
            at = a[mode][0] if a else None
            st = s[mode][0] if s else None
            ab = a[mode][1] if a else None
            sb = s[mode][1] if s else None
            lat = (at - st) / at * 100.0 if (at is not None and st is not None and at > 0) else None
            bw = (sb - ab) / ab * 100.0 if (ab is not None and sb is not None and ab > 0) else None
            entry[mode] = (at, st, lat, ab, sb, bw)
        rows.append((size, size_label(size), entry))
    return rows


def build_sheet(asym, sym, asym_src, sym_src):
    """asym/sym: parse_log 结果（可能为 None 表示该场景缺失）。返回 sheet xml。"""
    sh = Sheet()
    # ---- 行1-4：表头（复刻模板：蓝底白字加粗，行4小一号字）----
    sh.cell(1, 1, 1, '数据大小')
    sh.merge(1, 1, 4, 1)
    sh.cell(1, 2, 1, 'Out-of-place')
    sh.merge(1, 2, 2, 7)
    sh.cell(1, 8, 1, 'In-place')
    sh.merge(1, 8, 2, 13)
    sh.heights[1] = '22'
    sh.heights[2] = '22'
    sh.heights[3] = '28'
    sh.heights[4] = '22'
    for base in (2, 8):  # B 与 H 两大块结构相同
        sh.cell(3, base, 1, '非对称内存')
        sh.cell(3, base + 1, 1, '对称内存')
        sh.cell(3, base + 2, 1, '时延降低(%)')
        sh.merge(3, base + 2, 4, base + 2)
        sh.cell(4, base, 2, '时延(us)')
        sh.cell(4, base + 1, 2, '时延(us)')
        sh.cell(3, base + 3, 1, '非对称内存')
        sh.cell(3, base + 4, 1, '对称内存')
        sh.cell(3, base + 5, 1, '带宽提升(%)')
        sh.merge(3, base + 5, 4, base + 5)
        sh.cell(4, base + 3, 2, '带宽(GB/s)')
        sh.cell(4, base + 4, 2, '带宽(GB/s)')

    # ---- 数据行：两场景日志实际出现的尺寸并集，升序 ----
    rows = compute_rows(asym, sym)
    wrong_asym = [size_label(s) for s, d in sorted((asym or {}).items()) if d['wrong']]
    wrong_sym = [size_label(s) for s, d in sorted((sym or {}).items()) if d['wrong']]
    row = 5
    for _size, label, entry in rows:
        sh.cell(row, 1, 3, label)
        for mode_i, mode in ((0, 'oop'), (1, 'ip')):
            base = 2 + mode_i * 6
            at, st, lat, ab, sb, bw = entry[mode]
            sh.cell(row, base, 4, at, numeric=at is not None)
            sh.cell(row, base + 1, 4, st, numeric=st is not None)
            sh.cell(row, base + 2, pct_style(lat), lat, numeric=lat is not None)
            sh.cell(row, base + 3, 4, ab, numeric=ab is not None)
            sh.cell(row, base + 4, 4, sb, numeric=sb is not None)
            sh.cell(row, base + 5, pct_style(bw), bw, numeric=bw is not None)
        row += 1

    # ---- 说明区（复刻模板行23-27 + 数据来源）----
    row += 1  # 隔一空行
    notes = [
        '计算公式说明：',
        '时延降低(%) = (非对称内存时延 - 对称内存时延) / 非对称内存时延 × 100%',
        '带宽提升(%) = (对称内存带宽 - 非对称内存带宽) / 非对称内存带宽 × 100%',
        '说明：正数(绿色)表示 对称内存 比 非对称内存 性能更好，负数(红色)表示更差',
        '      输出 = Out-of-place模式，输入 = In-place模式',
        '数据来源：非对称内存=%s；对称内存=%s。仅统计实际测试的尺寸（共%d档），未测试的尺寸不列。' % (
            asym_src or '缺失', sym_src or '缺失', len(rows)),
    ]
    if asym is None:
        notes.append('场景A（非对称内存）日志缺失（未跑或未留产物），对应列留空。')
    if sym is None:
        notes.append('场景B（对称内存）日志缺失（未跑或未留产物），对应列留空。')
    if wrong_asym:
        notes.append('正确性校验失败(#wrong≠0)的尺寸--非对称内存：%s，其数据仅供参考。' % '、'.join(wrong_asym))
    if wrong_sym:
        notes.append('正确性校验失败(#wrong≠0)的尺寸--对称内存：%s，其数据仅供参考。' % '、'.join(wrong_sym))
    for i, text in enumerate(notes):
        sh.cell(row, 1, 8 if i == 0 else 9, text)  # 首行"计算公式说明："加粗（模板 s20/s21 之分）
        sh.merge(row, 1, row, 13)
        row += 1
    return sh.to_xml()


def write_xlsx(path, sheet_xml):
    parts = {
        '[Content_Types].xml': CONTENT_TYPES_XML,
        '_rels/.rels': RELS_XML,
        'xl/workbook.xml': workbook_xml(),
        'xl/_rels/workbook.xml.rels': WORKBOOK_RELS_XML,
        'xl/styles.xml': STYLES_XML,
        'xl/worksheets/sheet1.xml': sheet_xml,
    }
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name, content in parts.items():
            zf.writestr(name, content)


# ---------------------------------------------------------------------------
# HTML 报告生成（版式/图表JS 复刻《测试报告模版.html》；占位符 @@xxx@@ 替换动态内容）
# 说明：图表脚本引自模板的 CDN（chart.js@4.4.1）；离线打开时图表不渲染，
# 但 raw 数据与总结段仍是完整可读的。
# ---------------------------------------------------------------------------

HTML_TEMPLATE = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>对称内存 vs 非对称内存 性能对比报告</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: "Microsoft YaHei", "Segoe UI", sans-serif;
    background: #f4f6f9;
    color: #2b3440;
    padding: 32px 20px;
  }
  .container { max-width: 1180px; margin: 0 auto; }
  h1 { font-size: 24px; margin-bottom: 6px; }
  .subtitle { color: #7a8794; font-size: 14px; margin-bottom: 24px; }
  .summary {
    background: #fff;
    border-left: 4px solid #3b82f6;
    border-radius: 8px;
    padding: 18px 22px;
    line-height: 1.9;
    font-size: 15px;
    box-shadow: 0 1px 3px rgba(0,0,0,.06);
    margin-bottom: 28px;
  }
  .summary strong { color: #1d4ed8; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(480px, 1fr));
    gap: 22px;
  }
  .card {
    background: #fff;
    border-radius: 10px;
    padding: 20px;
    box-shadow: 0 1px 3px rgba(0,0,0,.06);
  }
  .card h2 { font-size: 16px; margin-bottom: 4px; }
  .card .tag { font-size: 12px; color: #94a3b8; margin-bottom: 14px; }
  .chart-box { position: relative; height: 320px; }
  .formula {
    margin-top: 28px; background: #fff; border-radius: 10px;
    padding: 18px 22px; font-size: 13px; color: #64748b; line-height: 1.8;
    box-shadow: 0 1px 3px rgba(0,0,0,.06);
  }
</style>
</head>
<body>
<div class="container">
  <h1>对称内存 vs 非对称内存 性能对比报告</h1>
  <div class="subtitle">数据大小 @@RANGE@@ · Out-of-place 模式 · 单位：时延(us)、带宽(GB/s)</div>

  <div class="summary">
    @@SUMMARY@@
  </div>

  <div class="grid">
    <div class="card">
      <h2>时延对比（越低越好）</h2>
      <div class="tag">非对称内存 vs 对称内存 · 单位 us</div>
      <div class="chart-box"><canvas id="latencyChart"></canvas></div>
    </div>
    <div class="card">
      <h2>带宽对比（越高越好）</h2>
      <div class="tag">非对称内存 vs 对称内存 · 单位 GB/s</div>
      <div class="chart-box"><canvas id="bwChart"></canvas></div>
    </div>
    <div class="card">
      <h2>时延降低百分比</h2>
      <div class="tag">正值=对称内存更优 · 负值=非对称内存更优</div>
      <div class="chart-box"><canvas id="latPctChart"></canvas></div>
    </div>
    <div class="card">
      <h2>带宽提升百分比</h2>
      <div class="tag">正值=对称内存更优 · 负值=非对称内存更优</div>
      <div class="chart-box"><canvas id="bwPctChart"></canvas></div>
    </div>
  </div>

  <div class="formula">
    时延降低(%) = (非对称内存时延 - 对称内存时延) / 非对称内存时延 × 100%<br>
    带宽提升(%) = (对称内存带宽 - 非对称内存带宽) / 非对称内存带宽 × 100%<br>
    说明：正数表示对称内存比非对称内存性能更好，负数表示更差。<br>
    @@SOURCE_NOTES@@
  </div>
</div>

<script>
// 数据：[size, OOP非对称时延, OOP对称时延, OOP时延降低%, OOP非对称带宽, OOP对称带宽, OOP带宽提升%,
//        IP非对称时延, IP对称时延, IP时延降低%, IP非对称带宽, IP对称带宽, IP带宽提升%]
const raw = @@RAW@@;
const labels = raw.map(r => r[0]);
const col = i => raw.map(r => r[i]);

const C = { asym:'#ef4444', sym:'#3b82f6', oop:'#8b5cf6', ip:'#10b981' };
const baseOpts = (yTitle) => ({
  responsive: true, maintainAspectRatio: false,
  interaction: { mode: 'index', intersect: false },
  plugins: { legend: { position: 'top' } },
  scales: {
    x: { title: { display: true, text: '数据大小' } },
    y: { title: { display: true, text: yTitle } }
  }
});
const ds = (label, data, color, dash) => ({
  label, data, borderColor: color, backgroundColor: color,
  borderWidth: 2, pointRadius: 3, tension: 0.25, fill: false,
  borderDash: dash || []
});

new Chart(latencyChart, {
  type: 'line',
  data: { labels, datasets: [
    ds('非对称内存', col(1), C.asym),
    ds('对称内存',   col(2), C.sym),
  ]},
  options: baseOpts('时延 (us)')
});

new Chart(bwChart, {
  type: 'line',
  data: { labels, datasets: [
    ds('非对称内存', col(4), C.asym),
    ds('对称内存',   col(5), C.sym),
  ]},
  options: baseOpts('带宽 (GB/s)')
});

const pctOpts = (yTitle) => {
  const o = baseOpts(yTitle);
  o.plugins.annotation = undefined;
  return o;
};

new Chart(latPctChart, {
  type: 'line',
  data: { labels, datasets: [
    ds('时延降低', col(3), C.oop),
  ]},
  options: pctOpts('时延降低 (%)')
});

new Chart(bwPctChart, {
  type: 'line',
  data: { labels, datasets: [
    ds('带宽提升', col(6), C.oop),
  ]},
  options: pctOpts('带宽提升 (%)')
});
</script>
</body>
</html>
'''


def _fmt2(v):
    """数值 -> 模板风格的显示文本（2位小数，去尾零）。"""
    if v is None:
        return '无数据'
    return ('%.2f' % round(v, 2)).rstrip('0').rstrip('.') if isinstance(v, float) else str(v)


def build_summary(rows, asym, sym):
    """总结段：从数据推导，不编造叙述。rows 是 compute_rows 的结果。"""
    if not rows:
        return '本轮没有可解析的 perf 数据。'
    first, last = rows[0][1], rows[-1][1]
    n = len(rows)
    if sym is None:
        return ('场景B（对称内存）日志缺失（未跑或未留产物），本轮无对比数据。'
                '报告仅呈现非对称内存侧实测数值（%s~%s 共%d档），图表中"对称内存"系列无数据点，'
                '性能对比结论以补齐场景B数据后的报告为准。' % (first, last, n))
    if asym is None:
        return ('场景A（非对称内存）日志缺失（未跑或未留产物），本轮无对比数据。'
                '报告仅呈现对称内存侧实测数值（%s~%s 共%d档），图表中"非对称内存"系列无数据点，'
                '性能对比结论以补齐场景A数据后的报告为准。' % (first, last, n))
    # 两场景都有：按 Out-of-place 模式统计（与模板叙述口径一致）
    lat = [(label, e['oop'][2]) for _s, label, e in rows if e['oop'][2] is not None]
    bw = [(label, e['oop'][5]) for _s, label, e in rows if e['oop'][5] is not None]
    parts = []
    if not lat:
        parts.append('两场景日志的尺寸范围没有交集，无法对比（各侧数据见下方图表与数据数组）。')
        return ''.join(parts)
    m = len(lat)
    lat_better = sum(1 for _l, v in lat if v > 0)
    lat_worse = sum(1 for _l, v in lat if v < 0)
    bw_better = sum(1 for _l, v in bw if v > 0)
    bw_worse = sum(1 for _l, v in bw if v < 0)
    best_lat = max(lat, key=lambda t: t[1])
    worst_lat = min(lat, key=lambda t: t[1])
    best_bw = max(bw, key=lambda t: t[1]) if bw else None
    worst_bw = min(bw, key=lambda t: t[1]) if bw else None
    parts.append('本报告对比了Out-of-place模式下对称内存与非对称内存在<strong>%s~%s</strong>共%d档数据块下的时延与带宽表现。'
                 % (first, last, n))
    if m < n:
        parts.append('其中%d档两侧数据齐全可对比，其余%d档单侧缺失未参与对比。' % (m, n - m))
    parts.append('时延方面：%d/%d档尺寸对称内存更低、%d档更高；时延降低最显著为<strong>%s%%（%s）</strong>，'
                 '最差为%s%%（%s）。' % (lat_better, m, lat_worse, _fmt2(best_lat[1]), best_lat[0],
                                        _fmt2(worst_lat[1]), worst_lat[0]))
    if best_bw:
        parts.append('带宽方面：%d/%d档尺寸对称内存更高、%d档更低；带宽提升最大为<strong>%s%%（%s）</strong>，'
                     '最低为%s%%（%s）。' % (bw_better, m, bw_worse, _fmt2(best_bw[1]), best_bw[0],
                                            _fmt2(worst_bw[1]), worst_bw[0]))
    last_entry = rows[-1][2]['oop']
    if last_entry[2] is not None:
        parts.append('最大尺寸%s：时延降低%s%%、带宽提升%s%%。'
                     % (last, _fmt2(last_entry[2]), _fmt2(last_entry[5])))
    parts.append('In-place模式的数据见本页数据数组与Excel对比表（测试数据对比.xlsx）。')
    return ''.join(parts)


def build_html(asym, sym, asym_src, sym_src):
    """生成 HTML 报告全文。asym/sym 为 parse_log 结果（None=场景缺失）。"""
    rows = compute_rows(asym, sym)
    wrong_asym = [size_label(s) for s, d in sorted((asym or {}).items()) if d['wrong']]
    wrong_sym = [size_label(s) for s, d in sorted((sym or {}).items()) if d['wrong']]
    first, last = rows[0][1], rows[-1][1]

    # raw 数组：13列（模板原结构），缺失值用 null（Chart.js 自动跳点）
    raw = []
    for _size, label, entry in rows:
        oop_at, oop_st, oop_lat, oop_ab, oop_sb, oop_bw = entry['oop']
        ip_at, ip_st, ip_lat, ip_ab, ip_sb, ip_bw = entry['ip']
        raw.append([label,
                    _r2(oop_at), _r2(oop_st), _r2(oop_lat), _r2(oop_ab), _r2(oop_sb), _r2(oop_bw),
                    _r2(ip_at), _r2(ip_st), _r2(ip_lat), _r2(ip_ab), _r2(ip_sb), _r2(ip_bw)])

    source_notes = ['数据来源：非对称内存=%s；对称内存=%s。仅统计实际测试的尺寸（共%d档），未测试的尺寸不列。'
                    % (escape(asym_src or '缺失'), escape(sym_src or '缺失'), len(rows))]
    if asym is None:
        source_notes.append('场景A（非对称内存）日志缺失（未跑或未留产物），对应数据为空。')
    if sym is None:
        source_notes.append('场景B（对称内存）日志缺失（未跑或未留产物），对应数据为空。')
    if wrong_asym:
        source_notes.append('正确性校验失败(#wrong≠0)的尺寸--非对称内存：%s，其数据仅供参考。' % '、'.join(wrong_asym))
    if wrong_sym:
        source_notes.append('正确性校验失败(#wrong≠0)的尺寸--对称内存：%s，其数据仅供参考。' % '、'.join(wrong_sym))

    html = HTML_TEMPLATE
    html = html.replace('@@RANGE@@', '%s ~ %s' % (first, last))
    html = html.replace('@@SUMMARY@@', build_summary(rows, asym, sym))
    html = html.replace('@@RAW@@', json.dumps(raw, ensure_ascii=False))
    html = html.replace('@@SOURCE_NOTES@@', '<br>\n    '.join(escape(n) for n in source_notes))
    return html


def _r2(v):
    """数值 -> round(v,2)（None 透传，json 序列化成 null）。"""
    return None if v is None else round(v, 2)


def write_text(path, content):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog='mccl-data-report.py',
        description='解析场景A/B原始日志，一次生成两份对比产物：测试数据对比.xlsx（按《测试数据对比模版.xlsx》版式）'
                    '与 测试报告.html（按《测试报告模版.html》版式的 Chart.js 图表报告）。'
                    '只统计实际测试的尺寸；带宽取 busbw 口径。')
    ap.add_argument('--run-dir', help='run 目录：自动选各场景最终日志'
                                      '（有 test-*.retry-<k>.log 取最大 k，否则首次 test-*.log）')
    ap.add_argument('--asym', help='场景A（非对称内存）日志路径，显式指定')
    ap.add_argument('--sym', help='场景B（对称内存）日志路径，显式指定')
    ap.add_argument('--out', help='输出 xlsx 路径（--run-dir 模式默认 <run-dir>/测试数据对比.xlsx）')
    ap.add_argument('--html-out', help='输出 html 路径（默认：--run-dir 模式取 <run-dir>/测试报告.html；'
                                       '显式日志模式取 --out 同目录下的 测试报告.html）')
    args = ap.parse_args(argv)

    if not args.run_dir and not (args.asym or args.sym):
        sys.stderr.write('错误：需给 --run-dir，或至少给 --asym/--sym 之一\n')
        return 2
    if not args.run_dir and not args.out:
        sys.stderr.write('错误：显式日志模式下 --out 必填\n')
        return 2

    asym_src = sym_src = None
    if args.run_dir:
        if not os.path.isdir(args.run_dir):
            sys.stderr.write('错误：run 目录不存在：%s\n' % args.run_dir)
            return 2
        if not args.out:
            args.out = os.path.join(args.run_dir, '测试数据对比.xlsx')
        if not args.html_out:
            args.html_out = os.path.join(args.run_dir, '测试报告.html')
        if args.asym:
            asym_src = args.asym
        else:
            asym_src = pick_final_log(args.run_dir, 'asymmetric')
        if args.sym:
            sym_src = args.sym
        else:
            sym_src = pick_final_log(args.run_dir, 'symmetric')
    else:
        asym_src = args.asym
        sym_src = args.sym
        if not args.html_out:
            args.html_out = os.path.join(os.path.dirname(os.path.abspath(args.out)) or '.',
                                         '测试报告.html')

    asym = parse_log(asym_src) if asym_src and os.path.isfile(asym_src) else None
    sym = parse_log(sym_src) if sym_src and os.path.isfile(sym_src) else None
    if asym_src and not os.path.isfile(asym_src):
        sys.stderr.write('警告：场景A日志不存在：%s\n' % asym_src)
    if sym_src and not os.path.isfile(sym_src):
        sys.stderr.write('警告：场景B日志不存在：%s\n' % sym_src)

    if not asym and not sym:
        sys.stderr.write('错误：两份日志都没有可解析的 perf 数据，不生成对比产物（xlsx 与 html 均不生成）'
                         '（测试可能根本没跑起来，结论以 test-result.md / final-report.md 为准）\n')
        return 3

    asym_name = os.path.basename(asym_src) if asym_src and os.path.isfile(asym_src) else None
    sym_name = os.path.basename(sym_src) if sym_src and os.path.isfile(sym_src) else None
    write_xlsx(args.out, build_sheet(asym, sym, asym_name, sym_name))
    write_text(args.html_out, build_html(asym, sym, asym_name, sym_name))
    print('已生成：%s' % args.out)
    print('已生成：%s' % args.html_out)
    print('  非对称内存来源：%s' % (asym_src or '缺失'))
    print('  对称内存来源：%s' % (sym_src or '缺失'))
    print('  尺寸档数：%d' % len(set(asym or {}) | set(sym or {})))
    return 0


if __name__ == '__main__':
    sys.exit(main())
