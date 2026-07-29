#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MCCL 环境变量 loader：读 mccl-env.json，算派生量，emit bash `export`。

为什么是这个形态（方案 B）：
  配置脱离 bash 语法、OS 无关（Windows/macOS/Linux 同一份 JSON）；本 loader 是跨平台
  Python，emit 的 bash export 由 agent 在本地 bash 里 eval（Windows 走 WSL）。执行层仍是
  bash（ssh/docker exec/mpirun 都是 Linux 工具），但配置文件不再绑定 bash。

用法（agent / setup-ssh 的 bash 里）：
    eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")"

  - 默认经 `git rev-parse --show-toplevel` 找 $REPO_ROOT/mccl-env.json；也可把 json 路径
    作为参数显式传入：python3 mccl-env-load.py /path/to/mccl-env.json
  - --keys：只打印全部变量名（raw + derived），给 tests/check.sh 不变式7 核对引用闭合用。
  - 只在本地跑：设本地 bash 变量，再由 agent 本地展开进 ssh 命令；远端机器不需要 python3。
  - 跳过 _ 前缀键（如 _comments），只收 MCCL_ 开头的键。

派生关系（不可手填，改 raw 自动跟；tests/check.sh 不变式12 会跑两个输入验证非写死）：
    MCCL_NODE0_IP      = MCCL_NODES 的第一个词
    MCCL_NNODES        = MCCL_NODES 的词数
    MCCL_NP            = MCCL_NNODES * MCCL_GPUS_PER_NODE
    MCCL_HOST_SPEC     = "ip:gpus,ip:gpus,..."
    MCCL_MACA_LIB_DIR  = MCCL_MACA_PATH + "/lib"
    MCCL_REMOTE_SRC    = MCCL_REMOTE_WORKDIR + "/" + MCCL_REMOTE_SRC_REPO_NAME
    MCCL_LD_LIBRARY_PATH = MCCL_MACA_LIB_DIR + ":" + MCCL_OMPI_LIB_PATH
"""
import json
import os
import shlex
import subprocess
import sys

# 必需的 raw 键（缺任一则报错退出，等价于原 .sh 里 : "${VAR:?...}" 的兜底）
REQUIRED_RAW = [
    "MCCL_NODES",
    "MCCL_GPUS_PER_NODE",
    "MCCL_SSH_OPTS",
    "MCCL_CONTAINER",
    "MCCL_MACA_PATH",
    "MCCL_VENDOR_MACA_PATH",
    "MCCL_REMOTE_WORKDIR",
    "MCCL_LOCAL_SRC",
    "MCCL_REMOTE_SRC_REPO_NAME",
    "MCCL_MPIRUN",
    "MCCL_PERF_BIN_ASYM",
    "MCCL_PERF_BIN_SYM",
    "MCCL_OMPI_LIB_PATH",
    "MCCL_TCP_IF_INCLUDE",
]


def parse_args(argv):
    """返回 (json_path, keys_only)。json_path 为 None 时后续用 git rev-parse 找。"""
    keys_only = False
    json_path = None
    for a in argv[1:]:
        if a == "--keys":
            keys_only = True
        elif not a.startswith("-"):
            json_path = a
    return json_path, keys_only


def find_json_path(explicit):
    if explicit:
        return explicit
    try:
        repo_root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        sys.stderr.write(
            "mccl-env-load: 不在 git 仓库里，无法定位 mccl-env.json；"
            "请把 json 路径作为参数传入，或在 MCCL 仓库内运行。\n"
        )
        sys.exit(1)
    return os.path.join(repo_root, "mccl-env.json")


def derive(raw):
    """从 raw 键算 7 个派生量。"""
    nodes = str(raw["MCCL_NODES"]).split()
    gpus = int(raw["MCCL_GPUS_PER_NODE"])
    maca_lib_dir = "{}/lib".format(raw["MCCL_MACA_PATH"])
    return {
        "MCCL_NODE0_IP": nodes[0],
        "MCCL_NNODES": len(nodes),
        "MCCL_NP": len(nodes) * gpus,
        "MCCL_HOST_SPEC": ",".join("{}:{}".format(ip, gpus) for ip in nodes),
        "MCCL_MACA_LIB_DIR": maca_lib_dir,
        "MCCL_REMOTE_SRC": "{}/{}".format(
            raw["MCCL_REMOTE_WORKDIR"], raw["MCCL_REMOTE_SRC_REPO_NAME"]
        ),
        "MCCL_LD_LIBRARY_PATH": "{}:{}".format(
            maca_lib_dir, raw["MCCL_OMPI_LIB_PATH"]
        ),
    }


def main():
    json_path_arg, keys_only = parse_args(sys.argv)
    path = find_json_path(json_path_arg)
    if not os.path.isfile(path):
        sys.stderr.write(
            "mccl-env-load: 找不到 {}\n"
            "请先 cp <插件>/mccl-env.json.example ./mccl-env.json 并填入真实值。\n".format(path)
        )
        sys.exit(1)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    # 只收 MCCL_ 开头的键，跳过 _comments 等
    raw = {k: v for k, v in data.items() if k.startswith("MCCL_")}

    missing = [k for k in REQUIRED_RAW if k not in raw]
    if missing:
        sys.stderr.write(
            "mccl-env-load: {} 缺少必需键：{}\n".format(path, ", ".join(missing))
        )
        sys.exit(1)

    all_vars = dict(raw)
    all_vars.update(derive(raw))

    if keys_only:
        for k in all_vars:
            print(k)
        return

    for k in sorted(all_vars):
        print("export {}={}".format(k, shlex.quote(str(all_vars[k]))))


if __name__ == "__main__":
    main()
