# MCCL 远程操作模式

**读者**：开发agent、测试agent。执行任何远程命令（rsync/ssh/docker exec/scp/mpirun）前必读，尤其是第1、2节——引号嵌套和路径分层猜错，代价是一整轮32卡集群时间。

路径统一用`$MCCL_*`变量（定义见`mccl-env.sh`，模板见`mccl-env.sh.example`）。`/opt/maca`是MetaX MACA SDK的厂商标准安装路径，作为说明性上下文出现，不代表agent应该往这个路径写东西。

## 0. 基本形态：编译在容器内，运行在宿主机

编译节点（`$MCCL_NODE0_IP`）上跑着一个容器（`$MCCL_CONTAINER`），源码同步、编译都在容器内完成。但跨节点32卡MPI验证在**宿主机**上跑，因为跨节点连通性（ssh）依赖宿主机网络，而**容器内没有装ssh客户端**。这条边界决定了下面每一步该在哪一层执行。

## 1. `ssh` + `docker exec` 引号嵌套模板（最容易猜错的地方）

标准形态：

```bash
ssh root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'export MACA_PATH=$MCCL_MACA_PATH && cd $MCCL_REMOTE_SRC && <实际命令>'"
```

**为什么是这个引号层级，不能反过来或者少一层：**

- 整条命令是**本地shell**里的一条双引号字符串，作为ssh的远程命令参数传出去。本地shell在双引号内会做变量展开——`$MCCL_NODE0_IP`、`$MCCL_CONTAINER`、`$MCCL_MACA_PATH`、`$MCCL_REMOTE_SRC`这些agent自己`source mccl-env.sh`后已知的变量，**在本地就被替换成真实值**，之后才发给ssh。
- 注意：双引号内部出现的单引号**不是嵌套引用**，只是普通字符——bash的引号规则里，单引号在双引号内没有特殊含义，不会开启二次转义层。所以`'...'`这部分不会被本地shell当成"再包一层"，变量展开照常发生在整个双引号字符串内，包括看起来在单引号里的那段。
- 这串（此时`$MCCL_*`已替换为真实值、但单引号字符原样保留）作为一个整体，通过ssh发到`$MCCL_NODE0_IP`的**远程shell**执行。远程shell这次是真正按shell语法解析这个字符串，这时候单引号才起作用：它把`docker exec $MCCL_CONTAINER bash -c`的参数括成一个整体，交给`bash -c`当一整条命令执行——**这一层单引号是留给远程shell用的，不是留给本地shell的**。
- 所以：**外层双引号是本地shell的，内层单引号是远程shell传给`bash -c`的**，两层各自服务不同的解析者，缺一层或次序反了，要么变量在本地展不开（远程收到字面量`$MCCL_MACA_PATH`），要么`docker exec`拿到的参数被本地shell提前拆散。

如果命令本身含有需要**在远程/容器内**才展开的变量（而不是本地`$MCCL_*`环境变量），要用反斜杠转义`\$`，避免本地shell提前展开成空值。目前`测试.md`里出现的远程命令均使用`$MCCL_*`（本地已知值）或`&&`拼接的字面命令，没有出现需要远程展开的变量，暂无此类反例可引用。

## 2. `/opt/maca/lib` 的双重身份（隐蔽陷阱）

第4节会说"4个节点**宿主机**的`/opt/maca/lib/`都不更新"，但下面第5节Node 0的分发命令里确实执行了`cp libmccl.so /opt/maca/lib/`——这两句话不矛盾，因为它们说的不是同一层：

- 第4节的"不更新"，指的是**宿主机文件系统**上的`/opt/maca/lib/`。
- 第5节Node 0那条`cp`命令，是`ssh ... "docker exec $MCCL_CONTAINER bash -c 'cp ... /opt/maca/lib/'"`——**先进了容器**，`cp`是在容器内执行的。容器内也有一条路径叫`/opt/maca/lib/`，但它和宿主机的`/opt/maca/lib/`是两个独立的文件系统位置，只是**路径字符串碰巧同名**，之间没有bind mount。

结论：看到`/opt/maca/lib`时，先确认命令是不是套了`docker exec`——套了就是容器内的那份（单节点验证用这份，走`LD_LIBRARY_PATH`默认搜索路径或直接覆盖系统库），没套就是宿主机的那份（**永远不touch，测试.md明确禁止**）。跨节点验证走的不是这条路径，而是`$MCCL_REMOTE_WORKDIR`下的MACA lib目录（见第4节）。

## 3. Node 0 与 Node 1/2/3 分发方式不同

| | Node 0（`$MCCL_NODE0_IP`，编译节点） | Node 1/2/3（`$MCCL_NODE1_IP`/`$MCCL_NODE2_IP`/`$MCCL_NODE3_IP`） |
|---|---|---|
| 编译产物来源 | 本机容器内`build/`目录，容器路径与宿主机`$MCCL_REMOTE_SRC`是同一份（bind mount），产物直接可见 | 无，只能接收 |
| 分发动作 | `ssh`进宿主机后`docker exec`进容器，容器内`cp`到容器内`/opt/maca/lib/` | 从Node 0直接`scp`到目标节点的`$MCCL_REMOTE_WORKDIR`下的MACA lib目录（宿主机层，不经容器） |
| 用途 | 单节点8卡验证（容器内跑，见第4节），只需容器内库路径生效 | 跨节点32卡验证，mpirun在宿主机跑，通过`LD_LIBRARY_PATH`指向宿主机上的这份库 |
| 是否可编译/改源码 | 是，唯一编译节点 | 否，硬禁令（见`references/mccl-safety.md`第1条），只接受scp来的`libmccl.so` |

为什么不同：单节点验证依赖容器内环境（含容器内的库），而跨节点验证的mpirun进程跑在宿主机、且需要ssh连通4台宿主机——容器内没有ssh，天然做不了跨节点编排，所以跨节点用的库必须放在宿主机能直接读到的路径上，不能留在容器里。

## 4. 单节点 vs 跨节点验证：为什么命令形态不同

- **单节点8卡**：在容器内跑，加`--mca plm isolated`，不依赖ssh。用于快速验证编译产物本身能跑通，不涉及跨节点通信路径。
- **跨节点32卡**：在宿主机跑，mpirun通过`-host`拉起4台节点的进程，依赖宿主机ssh互通。**容器内没有ssh，这一步不可能在容器内做。**
- 如果目标宿主机GLIBC版本与编译环境不匹配（`测试.md`提到Node 0系统为特定GLIBC版本），跨节点验证会不可用，此时**退回容器内单节点验证**作为替代手段——这是唯一能确认编译产物本身正确性的兜底路径。

## 5. SSH跳板拓扑

- 并非4个节点都能从agent的工作环境直连。按`测试.md`记录：编译节点（`$MCCL_NODE0_IP`）和其中一个计算节点（`$MCCL_NODE1_IP`，对应硬件拓扑表里排第一的非编译节点）可以直连；另外两个节点（`$MCCL_NODE2_IP`、`$MCCL_NODE3_IP`）**必须通过`$MCCL_NODE0_IP`跳转**，形态是`ssh`套`ssh`（或套`scp`）：

```bash
ssh root@$MCCL_NODE0_IP "ssh root@<目标节点IP> ..."
ssh root@$MCCL_NODE0_IP "scp <本地路径> root@<目标节点IP>:<远程路径>"
```

- （推断）分发`libmccl.so`到Node 1/2/3的三条命令（见第3节）实际上**全部**经由`$MCCL_NODE0_IP`发起`scp`，包括可以直连的那一台。`测试.md`原文没有解释这是否只是操作习惯统一、还是编译产物本身只存在于Node 0宿主机文件系统上（容器bind mount出来的），所以就地`scp`最省事。当前文档采信"产物就在Node 0宿主机上，从那里scp最直接"这一推断，但这属于推断，不是`测试.md`明文写出的因果。
- 具体哪个节点直连、哪个需要跳转，`mccl-env.sh`里没有单独变量标注这一属性；agent执行前应参照`测试.md`原始记录或向人工确认拓扑关系，不要凭IP数值大小或命名习惯猜测。

## 6. 容器内无SSH客户端 → 能力边界

容器（`$MCCL_CONTAINER`）里没有装ssh客户端。由此划出一条硬边界：

| 必须在**容器内**做 | 必须在**宿主机**做 |
|---|---|
| 源码编译（`make`） | 跨节点分发（`scp`到其他节点） |
| 单节点8卡验证（`--mca plm isolated`） | 跨节点32卡`mpirun`验证 |
| 容器内库路径的`cp`（第2节） | ssh跳转到其他节点 |

任何需要"连到另一台机器"的动作，都不能写成"进容器后再ssh出去"——容器里没有这个可执行文件，命令会直接失败。凡涉及跨节点连通的步骤，必须先退出容器语境（即命令不套`docker exec`），在宿主机shell层执行。

## 7. rsync的`--exclude`

全量同步命令（源码本地 → `$MCCL_NODE0_IP`上的`$MCCL_REMOTE_SRC`）排除三项：

```bash
rsync -avz --delete --exclude='build/' --exclude='.git/' --exclude='*.so' \
  $MCCL_LOCAL_SRC/ root@$MCCL_NODE0_IP:$MCCL_REMOTE_SRC/
```

- `--exclude='build/'`：`build/`是远程容器内产生的编译产物目录，不该被本地（大概率没有编译过、或编译配置不同）的`build/`覆盖，否则会破坏远程已有的增量编译缓存（尤其是`build/macaify/`，见`references/mccl-build-pitfalls.md`第2条），逼着下一次编译从全量重来。
- `--exclude='.git/'`：本地git历史不需要同步到远程编译节点，纯粹是编译现场，同步过去只会占空间、且可能把本地未提交的`.git`元数据暴露到共享的远程环境。
- `--exclude='*.so'`：`.so`是编译产物，不是源码；本地不会有权威版本的`libmccl.so`，同步过去可能覆盖掉远程刚编译出来、还没来得及分发的产物。
- `--delete`：让远程`$MCCL_REMOTE_SRC`与本地源码树保持镜像（本地删除的文件，远程也删除），但因为上面三项被排除，`--delete`不会波及`build/`、`.git/`、`*.so`。

## 8. 单文件推送

只改了一两个文件时，不必等全量rsync扫描整棵树，直接推送改动的文件更快：

```bash
rsync -avz $MCCL_LOCAL_SRC/<相对路径> \
  root@$MCCL_NODE0_IP:$MCCL_REMOTE_SRC/<相对路径> \
&& ssh root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'export MACA_PATH=$MCCL_MACA_PATH && cd $MCCL_REMOTE_SRC && rm -rf build/macaify && cd build && make -j50'"
```

同样要清`build/macaify`再`make`（见`references/mccl-build-pitfalls.md`第2条），单文件推送不改变这一点——macaify的时间戳检测缺陷跟推送方式无关，只跟源文件是否变化有关。

## 9. 已知不一致 / 未标注推断（如实报告，不擅自拍板）

- 第5节标注的分发拓扑推断（"是否全部经由Node 0发起scp只是操作习惯还是文件位置限制"）未在`测试.md`中给出明确因果说明，已在正文标注**（推断）**。
- `测试.md`未给出`$MCCL_NODE1_IP`/`$MCCL_NODE2_IP`/`$MCCL_NODE3_IP`与"哪个可直连、哪个需跳转"之间显式的变量级映射（该映射只存在于原始记录的具体IP文本里，出于保密约束本文档不予转抄），执行前需要agent自行核对当次`mccl-env.sh`里的实际拓扑或询问人工，不能假定固定顺序对应固定的直连/跳转属性。
