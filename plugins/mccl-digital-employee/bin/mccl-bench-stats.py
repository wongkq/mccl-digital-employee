#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MCCL bench stats 聚合纯函数（子系统②⑤）。

被 mccl-bench-runner 调用聚合 mpirun perf 输出为 bench-stats.json。
也可直接命令行调用（子命令），供 tests/test-bench-stats.sh 单测。

schema（bench-stats.json 顶层 runs 数组，每元素一个 so_tag 的 run）：
  {"runs":[{"so_tag":"after","scenarios":[
    {"id":"sym-1k","bin":"...","params":"-b 1k -e 1k -f 2 -R 2","rounds":3,
     "metrics":{"algbw_GBs":{"mean":95.2,"min":94.1,"max":96.0},
                "busbw_GBs":{"mean":180.0,"min":178.0,"max":182.0}}}]}]}

metrics 键名固定 algbw_GBs / busbw_GBs（与 references/bench-report-template.md 闭环）。
"""
import json
import re
import statistics
import sys


def parse_perf_line(line):
    """从一行 perf 输出提取 algbw/busbw。返回 "algbw=<v> busbw=<v>"。
    仿 all_reduce_perf 输出 "size 1024 algbw 95.2 busbw 180.0"。
    找不到返回空串。"""
    m = re.search(r'algbw\s+([0-9.]+)\s+busbw\s+([0-9.]+)', line)
    if not m:
        return ""
    return "algbw={} busbw={}".format(m.group(1), m.group(2))


def aggregate_metrics(path):
    """读文件，每行用 parse_perf_line 提取 algbw/busbw，算 mean/min/max。
    返回 {"algbw_GBs":{mean,min,max},"busbw_GBs":{mean,min,max}}。
    空输入返回全 None。"""
    algs = []; buss = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            out = parse_perf_line(line)
            m = re.match(r'algbw=([0-9.]+) busbw=([0-9.]+)', out)
            if m:
                algs.append(float(m.group(1)))
                buss.append(float(m.group(2)))
    def stat(vs):
        if not vs:
            return {"mean": None, "min": None, "max": None}
        return {"mean": round(statistics.mean(vs), 3),
                "min": round(min(vs), 3), "max": round(max(vs), 3)}
    return {"algbw_GBs": stat(algs), "busbw_GBs": stat(buss)}


def build_run(so_tag, rounds, scenario_lines):
    """组装一个 so_tag 的 run JSON 字符串。
    scenario_lines: 每行 "<id>|<bin>|<params>|<metrics_json>"。"""
    scenarios = []
    for ln in scenario_lines:
        parts = ln.split("|", 3)
        if len(parts) != 4:
            continue
        sid, binp, params, mj = parts
        try:
            metrics = json.loads(mj)
        except Exception:
            metrics = {}
        scenarios.append({"id": sid, "bin": binp, "params": params,
                          "rounds": int(rounds), "metrics": metrics})
    return json.dumps({"so_tag": so_tag, "scenarios": scenarios},
                      ensure_ascii=False, indent=2)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: mccl-bench-stats.py <parse_perf_line|aggregate_metrics|build_run> ...\n")
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "parse_perf_line":
        print(parse_perf_line(sys.argv[2] if len(sys.argv) > 2 else ""))
    elif cmd == "aggregate_metrics":
        print(json.dumps(aggregate_metrics(sys.argv[2]), ensure_ascii=False))
    elif cmd == "build_run":
        so_tag = sys.argv[2]; rounds = sys.argv[3]
        lines = sys.argv[4:]
        print(build_run(so_tag, rounds, lines))
    else:
        sys.stderr.write("unknown subcommand: {}\n".format(cmd))
        sys.exit(2)


if __name__ == "__main__":
    main()
