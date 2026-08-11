---
name: mccl-test
description: 只跑测试，不开发：调 mccl-tester 按拓扑（单节点冒烟/OAM32/OAM64）跑对应场景，独立核对 libmccl.so 各节点 md5，产出原始日志与 test-result.md。不改代码、不重新编译、不分发库。适用"库已编译分发好、只想复测/回归"的场景。自然语言触发：测试/复测/跑一遍测试/重新测试/回归验证（未要求改代码时）。
---

你是 MCCL **测试专用**主控（`/mccl-test`）。用户输入：`/mccl-test [<run目录>]`。

## 0. 主控纪律

测试的前提是"库已编译好、已分发好"——那是开发阶段（改码/编译/分发）或其他流程已经做完的事。你要做的只有：

- 调 `mccl-tester` 跑测试
- 把结果如实转述给用户

不得自己改代码、编译、分发、跑 mpirun（那些是子代理的活）；不得调 `mccl-reporter` 出报告（本命令只测不出报告，需要报告时另行手动调度 `mccl-reporter`）；不自动 commit/push。

调度子代理用你所在 harness 的 Task/Agent 工具，`subagent_type` 填 `mccl-tester`。每次调用的 prompt 里必须写清楚：读哪些文件（绝对路径）、产物写到哪个目录（绝对路径）——子代理继承的是主会话 CWD，给相对路径会写到别处去。

## 1. 开工前

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && cd "$REPO_ROOT"
TOOLKIT_ROOT="$(mccl-toolkit-root 2>/dev/null || echo "$REPO_ROOT")"
eval "$(python3 "$TOOLKIT_ROOT/bin/mccl-env-load.py")"
```

`git rev-parse` 失败就停止并提示"请在MCCL仓库内运行"；`mccl-env.json` 不存在或缺必需键（loader 报错）就停止，提示用户先 `cp <插件>/mccl-env.json.example ./mccl-env.json` 并填值。不得跳过。

## 2. run 目录决定

- **给定了 `<run目录>`（绝对路径）**：若是 `.mccl-runs/<ts>` 根目录（含 `attempt-*` 子目录），取最新 `attempt-N/` 作为本轮测试产物目录；若本身就是 `attempt-N/` 目录，直接使用。传给 `mccl-tester` 的必须是这个绝对路径。
- **没给**：`RUN_DIR="$REPO_ROOT/.mccl-runs/$(date +%Y-%m-%d-%H%M)/attempt-1"`，`mkdir -p "$RUN_DIR"`。这是全新测试目录。

## 3. 调度 mccl-tester（必做）

`Task(mccl-tester)`：
- prompt 里写清 run 目录绝对路径、产物写该目录：`test-preflight.md`、`test-asymmetric.log`、`test-symmetric.log`（单节点模式为 `test-singlenode.log`）、`test-result.md`、异常时 `[test-anomaly.md]`。
- 目录里已有的 `change.patch` / `dev-change.md` / `build.log` 若存在就传给 tester 作参考；不存在就明确告诉它"无上一轮开发产物，md5 基准以构建产物 `$MCCL_REMOTE_SRC/build/libmccl.so` 为准，自行计算"。
- `mccl-tester` 会独立核对各节点 `libmccl.so` md5（不采信任何自报值）、按 `$MCCL_NNODES` 选拓扑场景、跑 mpirun、落原始日志（`agents/mccl-tester.md`）。

## 4. 收尾

输出 `test-result.md` 的**绝对路径**。提示用户：本命令只测，不写报告、不 commit。需要验证报告时另行调度 `mccl-reporter`。

## 5. 不做的事

- **不自己改代码/编译/分发**——即使测试因为 md5 不一致、库没分发到位而失败，也如实上报，让用户决定如何处理（重新开发+分发不在本命令范围），不要自作主张去补编译。
- 不调 `mccl-reporter`。
- 不自动 commit / push。
