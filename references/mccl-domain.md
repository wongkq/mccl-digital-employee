# MCCL 领域知识：对称内存与 FC AllReduce

**读者**：开发agent。涉及对称内存（symmetric memory）、FC kernel、`dev_runtime.cc`、`clique/`目录的改动前必读。

不确定或未经`测试.md`直接证实的推断，标注为**（推断）**；其余均可在`测试.md`中找到出处。

## 1. 拓扑常量（硬编码）

| 拓扑 | nNodes | nodeSize | GROUP（fc kernel模板参数） | extLsaSize = nodeSize + nNodes - 1 |
|---|---|---|---|---|
| OAM32 PCIe Switch | 4 | 8 | 8 | 11 |
| OAM64 PCIe Switch | 8 | 8 | 8 | 15 |

这些常量由`devrOamNodeCount()`根据CliqueManager拓扑**直接返回**，不经过hostHash动态计算（commit `b05c0cb`优化后的行为）。OAM32/64的8卡/节点数由PCIe Switch硬件结构决定，写死在代码里，不要假设它会跟着运行时拓扑重新计算。

## 2. 8+3 对称内存窗口 slot 语义

`extLsaRankList`共`extLsaSize`个slot，分两段：

| Slot范围 | 来源 | 含义 |
|---|---|---|
| `[0, nodeSize)` | `baseNode + i` | 本节点8个rank的LSA地址 |
| `[nodeSize, extLsaSize)` | `sameSocketRanks`过滤self后 | 跨节点同`peerSocketId`的3个rank |

**`extLsaRankList[r]`存的是world rank号（0..nRanks-1），不是slot索引。** 它用于`symMemoryMapLsaTeamExtended`决定某个rank的fabric handle映射到`lsaFlatBase + r * bigSize`的哪一段。这是最容易搞混的一点：`r`是数组下标（slot），数组里存的值才是world rank。

填充路径（在`mcclDevrInitOnce`中）：
- **`sameSocketRanks`路径**（OAM32/64当前实际走这条）：按`peerSocketId`筛选，按`r`升序排列，slot 8..10是过滤self后的3个peer
- **fallback路径**（dead code，当前拓扑不会走到）：按`localRank`取跨节点同位rank

## 3. 对称内存注册与内核执行全流程（AllReduce小消息，4节点OAM32）

1. **用户注册窗口**：`mcclCommWindowRegister`把任务推到`regTaskQueue`，`mcclGroupEndInternal`触发group task。
2. **注册任务**：`mcclDevrRegisterWindowTask`调用`symMemoryObtain` + `symWindowCreate`。
3. **内存映射**：`symMemoryObtain` → `symMemoryMapLsaTeamExtended`：
   - 导出：`mcMemExportToShareableHandle`把本rank的memHandle导出为Fabric handle
   - AllGather：`bootstrapAllGather`全局交换32个rank的Fabric handle
   - VA预留：`mcMemAddressReserve(extLsaSize × bigSize)`
   - 导入映射：循环`extLsaSize`个LSA slot，调`symMemoryImportAndMapSegmentsForRankOam`映射到`lsaFlatBase + r * bigSize`
4. **设备端window**：`symWindowCreate`创建`mcclWindow_vidmem`，关键字段：`lsaFlatBase`、`stride4G`、`mcOffset4K`、`lsaRank`。`mcMemcpyAsync`同步到device。
5. **检查注册类型**：`mcclGetSymRegType`——send和recv都设置`MCCL_WIN_COLL_SYMMETRIC`才走对称路径。
6. **填充LSA buffer指针**（`registerSymetricBuffers`）：
   ```cpp
   int lsaTeamSize = extLsaSize > 0 ? extLsaSize : lsaSize;
   for (int i = 0; i < lsaTeamSize && i < MAX_CLIQUE_SIZE && i < comm->nRanks; ++i) {
       mcclDevrGetLsaRankPtr(comm, sendWin, sendUserOffset, i, &input);
       work->clique.ptrs->inputs[i]  = input;
       mcclDevrGetLsaRankPtr(comm, recvWin, recvUserOffset, i, &output);
       work->clique.ptrs->outputs[i] = output;
   }
   ```
   `i`在这里是**LSA slot索引**（0..extLsaSize-1），不是world rank。`inputs[0..7]`=本节点8 rank，`inputs[8..10]`=跨节点同socket 3 rank。自己的buffer在`inputs[lsaSelf]`，`lsaSelf = rank % nodeSize`。
7. **填fcinfo**（`updateFcKernelCommonArgs`，OAM32/64分支）：
   - `useLocalTopo = false`，`info.rank = comm->rank`（0..nRanks-1，即world rank）
   - 对称路径（`usedSymetricMemory`）：`memcpy` `lsaTeamSize`（=extLsaSize）项到`info.ipc_input_buffer[]`和`info.ipc_output_buffer[]`
   - 非对称路径：只填`info.ipc_input_buffer[lsaSelf]`，`lsaSelf = info.rank % nodeSize`
8. **内核执行**（`fc8xn_3d_mesh_oneshot`）：
   ```cpp
   void *in_buffer  = (unk_t *)info.ipc_input_buffer[info.rank % GROUP];  // % GROUP(=nodeSize) 取 lsaSelf
   void *out_buffer = (unk_t *)info.ipc_output_buffer[info.rank % GROUP];
   ```

## 4. `info.rank` 语义与 `% GROUP` 修复

`CliqueManager::IsSupportMultiNode()`不匹配OAM32/OAM64拓扑，所以`useLocalTopo = false`。这条件分支决定了`info.rank`被填成**world rank**（0..nRanks-1），而不是节点内局部rank。

但`ipc_input_buffer[]`的下标是**LSA slot**（0..10，对OAM32），直接用`info.rank`索引会越界——rank 8就已经超出0..7的slot范围。修复方式是内核里改成`info.rank % GROUP`（`GROUP` = `nodeSize` = 8），取到`lsaSelf`。

由此外推的操作建议：写涉及`ipc_input_buffer`/`ipc_output_buffer`的内核代码时，任何直接用`info.rank`当下标的地方都要检查是否需要`% GROUP`——**（推断）**。`测试.md`记的是这一处具体修复，没有把它上升为"所有下标处都要查"的通则。

## 5. FC AllReduce 内核选型边界（OAM32，4节点32卡）

| 内核 | 最小 | 最大 | 上界来源 |
|---|---|---|---|
| `fc8xn_3d_mesh_oneshot`（OFC32_LL） | 1B | 16KB | `checkKernelInfos[]`的`byteEnd = LIMIT_16K_1 = 16385`，`src/enqueue.cc:849` |
| `fc8xn_3d_mesh_allreduce_unk`（OFC32_UNK） | 16KB+1 | 16MB | `CliqueManager::IsSupported()`的OAM32分支，`src/clique/CliqueManager.cc:655`：`AllReduce && totalBytes <= (16 * BYTE_1M)` |

判断链（顺序很重要）：
1. `CliqueManager::IsSupported(info)` → OAM32分支（line 655）：`totalBytes > 16MB`直接返回false，fallback到Ring/Tree。
2. `checkKernelInfos[]`在同族内核内部选型：0~16K用oneshot，16K+~NOLIMIT用unk——**但`IsSupported`已经在16MB处拦截过一次**，所以unk实际生效区间是16KB+1~16MB。
3. `FcByteLimit`默认8GB**对OAM32不生效**——OAM32分支在`IsSupported()`里提前return，不会走到通用限流判断（line 675附近）。改`FcByteLimit`不会改变OAM32的16MB上限，这个坑容易踩。

超过16MB自动回退Ring/Tree，不是内核bug，是设计如此。

## 6. `fc8xn_3d_mesh_allreduce_unk`：未启用，且有阻塞性bug

**Bug 1（启用前必须修）**：`allreduce_unk`内核读`info.in_buffer`/`info.out_buffer`，并按`R = 0..31`索引`in_buffer[OFC_IO_UNK(R)]`。但对称路径下这两个字段仍然是`first->sendbuff`/`first->recvbuff`——**单个rank的user buffer**，不是32个rank的数组。按0..31索引会越界读写。修复方案有两个方向（测试.md未定案，待设计）：方案A改内核索引逻辑，方案B改host端赋值把`in_buffer`/`out_buffer`填成真正的32项数组。**在没有修这个bug之前，不要启用这个内核。**

**跨节点寻址（已验证没问题）**：`allreduce_unk`的跨节点数据传输完全走FC clique channel（`switch_ipc_unk_base[g]`），**不经过**`inputs[8..10]`（LSA对称内存窗口）。`sameSocketRanks`与`seq_rankid`按相同规则（`peerSocketId` + r升序）构建，两者的集合和顺序一致，这部分不是风险点。

## 7. 已知风险

- `fc0_ipc_unk_base[0..7]`和`fc1_ipc_unk_base[0..3]`来自FC clique的`ipc_unk_buffer[]`，跨节点GIN/shared memory可见性需确认（测试.md未给出结论，视为待验证项）。
- 若FC clique跨节点共享不可达，会导致ATU地址翻译错误。
- `sameSocketRanks`路径要求`sameSocketRankCount == nNodes`。若`peerSocketId`分布不对称（`sameSocketRankCount < nNodes`），`extLsaRankList[8..10]`尾部slot为0（calloc零初始化保证），后续`symMemoryImportAndMapSegmentsForRankOam`用0当world rank会失败。**当前OAM32/64拓扑已验证`sameSocketRankCount == nNodes`，无此问题**——但如果要支持新拓扑，这条要重新验证（"新拓扑需重验"是从上句事实外推的操作建议，**（推断）**；`测试.md`只记了当前拓扑已验证这一点）。

## 8. 临时补丁史（反面教材）

| 补丁 | 状态 | 说明 |
|---|---|---|
| `021417e`（skip cross-node LSA） | 已revert | 被`37ba549`正式方案取代 |
| `a703e97`（skip UDS cross-node） | 已revert | 同上 |
| `37ba549`（8+3跨节点LSA） | 正式方案 | Fabric handle + 全局`bootstrapAllGather` |

`021417e`和`a703e97`是"跳过"不是"修复"——它们绕开了跨节点LSA/UDS路径而不是解决根因，属于绕过式补丁。两个都已revert，被`37ba549`的正式方案（本文第3节描述的Fabric handle + `bootstrapAllGather`流程）取代。**遇到类似问题时，"跳过某段逻辑让测试先过"不是可接受的修复方式**——参见`references/mccl-safety.md`中关于绕过性改动的规定。

对称内存的历史脉络：commit `781bb26` + `d97d865`引入对称内存（为OAM32/64 PCIe Switch拓扑的FC kernel提供跨rank直接寻址），`46c61db`、`88e0e1e`、`ee2b64e`修复8+3跨节点LSA bug。

### 遗留问题

对称路径测试结束时会刷`mcMemUnmap mcErrorInvalidValue`。不影响测试结果，revert TEMP patch时一并修（测试.md原话，未给出具体修复方案）。
