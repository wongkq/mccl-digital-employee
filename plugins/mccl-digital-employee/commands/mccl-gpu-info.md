---
description: 快查 GPU 基础信息：每主机一张 12 字段明细表（GPU 数/型号/驱动/MACA/显存/温度/功耗/Util/State/进程），出表 + 落到 /tmp/gpu-info-<ts>.html。想查 GPU 基础信息/看看 GPU 有没有被占用/拓扑/bin/温度/功耗 用这个；不跑带宽基准。
---

你是 GPU 基础信息快查入口。用户输入 `/mccl-gpu-info`或自然语言"查一下 GPU 基础信息 / 看看 GPU 有没有被占用 / GPU 拓扑合不合法 / bin 是否就绪 / GPU 数量型号驱动版本是什么 / GPU 每卡温度功耗多少"。

## 执行 1 步：跑 quick 探测（快口径：拓扑/bin 就绪/GPU 占用）

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")"
"$TOOLKIT_ROOT/bin/mccl-gpu-probe" --mode quick
```

退出码 0=READY / 1=NOT_READY / 2=error；读 stdout 的 gpu-verdict.json 报 verdict + failures。

## 执行 2 步：**主输出**——每台主机一张表（12 字段明细），同时落盘 HTML

**多主机按 $MCCL_NODES 逐台出一张表**，每台机原样执行一次：

```bash
ssh $MCCL_SSH_OPTS root@"$host" "mx-smi"
```

mx-smi 正常输出结构（MX-SMI 2.3.4）：头部含 `Attached GPUs: N`、`Kernel Mode Driver Version`、`MAC Version`；每卡行含型号、bus-id、GPU-Util、sGPU-M、功耗（如 `102W / 450W`)、温度（如 `34C`)、显存占用（如 `858/65536 MiB`)、GPU-State；下面 Processes 段列在跑进程。**每台主机只 ssh 一次、只跑一次 mx-smi，一主不少、不重复跑**，把输出按下表拆字段：

| # | 字段 | 从 mx-smi 哪里拆 |
|---|---|---|
| 1 | 主机名（每主机分标题) | hostname + ip |
| 2 | GPU 数量 | 头部 `Attached GPUs: N` 行 |
| 3 | GPU 型号 | 每卡第二列（如 MetaX C550) |
| 4 | 单卡显存 | 内存列右侧（如 `65536 MiB`，总显存） |
| 5 | 驱动版本 | 头部 `Kernel Mode Driver Version: x.y.z` 行 |
| 6 | MACA 版本 | 头部 `MACA Version: a.b.c.d` 行 |
| 7 | 单卡温度 | 每卡 `Temp` 列（如 34C / 37C） |
| 8 | 单卡功耗 | 每卡 `Pwr:Usage/Cap` 列（如 `102W / 450W`） |
| 9 | 显存占用 | 内存列左侧已用部分（如 858/65536 的 858) |
| 10 | GPU-Util | 每卡 `GPU-Util` 列（如 0%) |
| 11 | GPU-State | 每卡 `GPU-State` 列（如 Available) |
| 12 | 当前在跑进程 | Processes 段： `no process found` 写"无"，否则列出 PID+Name+显存 |

**终端输出模板**（ mx-smi 缺哪个字段哪格写"未覆盖"，**不得脑补**）：

```
# 主机： <hostname>（$MCCL_NODES[0])
- GPU 数： <8>   型号： <MetaX C550>   单卡显存： <65536 MiB>
- 驱动： <3.8.3>   MACA： <3.7.2.0>

| GPU# | 温度 | 功耗 | GPU-Use:Util | GPU-State | 显存占用 | 进程 |
| 0    | 34C  | 102W/450W | 0% | Available | 858/65536 MiB | — |
...

# 主机2: <hostname>（$MCCL_NODES[1]）
```

**同时落盘 HTML**：把上面整段内容原样写入 `$REPO_ROOT/.mccl-gpu-info-<YYYY-MM-DD-HHMM>.html`（如 .mccl-gpu-info-2408021201.html）：把整段（主机标题 + 每张表）包进 `<html><body><pre>` ...`</pre></body></html>`，一行不丢。极简包装，不要美化——HTML 只是把终端里打出的内容原样落一份。

告知用户 HTML 路径（完整绝对路径）。

## 硬约束

- 不跑带宽基准（不查 gpu_health_check.sh、不跑 mxvs）；带宽/健康检查在 /mccl-run 的 mccl-prober（`--mode full`）阶段。
- 不改文件、不杀进程、不下现铺的测试动作——GPU 有进程就如实报告 failures 落盘，绝不替人工决定。
- 字段缺失标记"未覆盖"，**不得从其他主机/其他卡类推**。
- HTML 版本与终端打出的一致——不得省略任何一段。

## 例证：某主机 ssh 不可达（gpu-verdict 的 occupied[] 里出现"网络不可达"或 verdict=error 且该 host 在 failures 里）

把这台单独出一段：
- 主机标题：`host<IP>：ssh 不可达（网络/密钥问题）`
- 12 字段全填`未覆盖`
- 其他主机照常出
- HTML同步包含这一段（未覆盖段也一样进 HTML，不裁）
