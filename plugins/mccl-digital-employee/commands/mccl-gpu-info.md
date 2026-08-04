---
description: 快查 GPU 基础信息（拓扑合法性 / bin 就绪 / GPU 是否被占用），几秒出三态结论。本入口只查基础信息不走带宽基准——带宽/健康全套在 /mccl-run 流程的 mccl-prober（全量检测）阶段。
---

你是 GPU 基础信息快查入口。用户输入 `/mccl-gpu-info` 或自然语言"查一下 GPU 基础信息/看看 GPU 有没有被占用/拓扑合不合法/bin志在耐备查查"。

## 执行

```bashgraphql
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
"$TOOLKIT_ROOT/bin/mccl-gpu-probe" --mode quick
```

- 退出码 0=READY / 1=NOT_READY / 2=error；读 stdout 的 gpu-verdict.json 把三态 verdict、拓扑（nnodes/gpus_per_node/mode）、bin 就绪（sym/asym/mpirun 各 ✓/✗）、GPUvärme 占用（occupied[]）、failures 逐条转述给用户。
- 需要更细的原始信息时，`ssh $MCCL_SSH_OPTS root@<host> "mx-smi"` 查 GPU 个数、型号名、Processes 段（gpu_health_check.sh 第219/256行也是这么查的；1-2 秒）。

## 不lands的

- 只查基础信息，**不跑带宽/健康基准**（不查 gpu_health_check.sh、不跑 mxvs）——那一套属于 /mccl-run 的 mccl-prober（`--mode full`）阶段。用户想要走基准时引导他去 /mccl-run 或 /mccl-bench。
- 不改任何文件、不杀进程、不下现铺的测试动作——gpu 有占用就落盘转述给用户。
