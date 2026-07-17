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

## 2. `/opt/maca/lib`（即`$MCCL_VENDOR_MACA_PATH/lib`）的双重身份（隐蔽陷阱）

本节按路径**字符串**讲，所以写字面量`/opt/maca/lib`——重点恰恰是"同一个字符串在两层各指一处"。实际执行的命令里一律用`$MCCL_VENDOR_MACA_PATH/lib`（第3节动作①）。

第3节会说"4个节点**宿主机**的`/opt/maca/lib/`都不更新"，但同一节Node 0的分发动作①里确实执行了`cp libmccl.so /opt/maca/lib/`——这两句话不矛盾，因为它们说的不是同一层：

- 第3节的"不更新"，指的是**宿主机文件系统**上的`/opt/maca/lib/`。
- 第3节Node 0那条`cp`命令，是`ssh ... "docker exec $MCCL_CONTAINER bash -c 'cp ... /opt/maca/lib/'"`——**先进了容器**，`cp`是在容器内执行的。容器内也有一条路径叫`/opt/maca/lib/`，但它和宿主机的`/opt/maca/lib/`是两个独立的文件系统位置，只是**路径字符串碰巧同名**，之间没有bind mount。

结论：看到`/opt/maca/lib`时，先确认命令是不是套了`docker exec`——套了就是容器内的那份（单节点验证用这份，走`LD_LIBRARY_PATH`默认搜索路径或直接覆盖系统库），没套就是宿主机的那份（**永远不touch，测试.md明确禁止**）。跨节点验证走的不是这条路径，而是`$MCCL_REMOTE_WORKDIR`下的MACA lib目录，即`$MCCL_MACA_LIB_DIR`（分发动作见第3节表格与命令）。

注意`$MCCL_MACA_LIB_DIR`与`/opt/maca/lib`在"容器内外是否同一份"这件事上正好相反，这是本节最容易搞反的地方：`/opt/maca/lib`容器内外**同名但是两份**（无bind mount，容器内写了宿主机看不见）；`$MCCL_MACA_LIB_DIR`在`$MCCL_REMOTE_WORKDIR`下，容器内外**是同一份**（有bind mount，容器内写了宿主机立刻看得见）。正因为如此，Node 0给跨节点用的那份库才可以在容器内`cp`进去（第3节动作②）——这不是绕过宿主机，而是同一个目录的两个入口。

## 3. Node 0 与 Node 1/2/3 分发方式不同

**前提：4个节点宿主机的`/opt/maca/lib/`一律不更新**（`测试.md`明确禁止）。单节点验证用的是容器内那份同名目录；跨节点验证用的是`$MCCL_MACA_LIB_DIR`——两条路径互不相干，下面的表格就是按这条边界展开的。

`libmccl.so`编译出来停在`$MCCL_REMOTE_SRC/build/`里（编译流程只有`make -j50`，**没有`make install`**，产物不会自动进任何lib目录），必须靠下面的动作显式分发。

| | Node 0（`$MCCL_NODE0_IP`，编译节点） | Node 1/2/3（`$MCCL_NODE1_IP`/`$MCCL_NODE2_IP`/`$MCCL_NODE3_IP`） |
|---|---|---|
| 编译产物来源 | 本机容器内`build/`目录，容器路径与宿主机`$MCCL_REMOTE_SRC`是同一份（bind mount），产物直接可见 | 无，只能接收 |
| 分发动作①<br>（给**单节点8卡**验证） | `ssh`进宿主机后`docker exec`进容器，容器内`cp`到容器内`/opt/maca/lib/` | 不适用——单节点验证只在Node 0的容器内跑 |
| 分发动作②<br>（给**跨节点32卡**验证） | 同样`docker exec`进容器内`cp`，但目标是`$MCCL_MACA_LIB_DIR`。该目录位于`$MCCL_REMOTE_WORKDIR`下，容器内与宿主机是**同一份**（bind mount），所以在容器内写进去，宿主机上的mpirun就能加载到——**不需要、也没有第二条把它送出容器的动作** | 从Node 0直接`scp`到目标节点的`$MCCL_MACA_LIB_DIR`（宿主机层，不经容器） |
| 是否可编译/改源码 | 是，唯一编译节点 | 否，硬禁令（见`references/mccl-safety.md`第1条），只接受scp来的`libmccl.so` |

**Node 0 的两个分发动作都要做，缺一不可**，它们服务的是两种不同的验证，落点是两个不同的目录：动作①的`/opt/maca/lib/`只有容器内进程看得见，单节点8卡验证在容器内跑，够用；动作②的`$MCCL_MACA_LIB_DIR`才是跨节点32卡mpirun（跑在**宿主机**上）通过`LD_LIBRARY_PATH`真正加载的那份。只做①不做②，Node 0在32卡测试里加载的仍是上一次的旧库或根本没有这个文件——而测试agent的preflight会对**四个**节点的`$MCCL_MACA_LIB_DIR`逐个`md5sum`，Node 0这一处第一时间就对不上。

四条分发命令（引号层级见第1节，跳板规则见第5节）：

```bash
# Node 0 动作①：单节点8卡验证用（容器内的厂商 MACA lib 目录，宿主机看不见）
ssh root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'cp $MCCL_REMOTE_SRC/build/libmccl.so $MCCL_VENDOR_MACA_PATH/lib/'"

# Node 0 动作②：跨节点32卡验证用（bind mount 目录，宿主机 mpirun 加载的就是这份）
ssh root@$MCCL_NODE0_IP "docker exec $MCCL_CONTAINER bash -c 'cp $MCCL_REMOTE_SRC/build/libmccl.so $MCCL_MACA_LIB_DIR/'"

# Node 1/2/3：宿主机层 scp，源文件经 bind mount 在 Node 0 宿主机上直接可见，不套 docker exec
ssh root@$MCCL_NODE0_IP "scp $MCCL_REMOTE_SRC/build/libmccl.so root@$MCCL_NODE1_IP:$MCCL_MACA_LIB_DIR/"
ssh root@$MCCL_NODE0_IP "scp $MCCL_REMOTE_SRC/build/libmccl.so root@$MCCL_NODE2_IP:$MCCL_MACA_LIB_DIR/"
ssh root@$MCCL_NODE0_IP "scp $MCCL_REMOTE_SRC/build/libmccl.so root@$MCCL_NODE3_IP:$MCCL_MACA_LIB_DIR/"
```

为什么Node 0与Node 1/2/3的动作②形态不同（一个`docker exec`+`cp`、一个`scp`）：目标目录是同一个（`$MCCL_MACA_LIB_DIR`），只是Node 0上这个目录本机就有、且容器内可直接写到，而另外三台要跨机器传输、且容器内没有ssh/scp客户端（见第6节），只能在宿主机层发起。

**这一步（Node 0 动作②）是本工具包相对`测试.md`原始工作流的补充，不是抄来的。** `测试.md`的"分发`libmccl.so`到4节点"一节只有三条`scp`（发往Node 1/2/3）加一条Node 0容器内到`/opt/maca/lib/`的`cp`，Node 0的`$MCCL_MACA_LIB_DIR`从头到尾没有被写过；同时全文只有`make -j50`、没有`make install`，产物也不会自流进去。也就是说，照`测试.md`的字面步骤执行，Node 0在32卡验证时加载的`libmccl.so`并非本次构建产物——这是原始工作流里一个真实存在的洞（原文当时能跑通，最可能是该文件由更早的某次操作留在了那里，`测试.md`未记载，本文档不替它补设定），不是本工具包新发明的要求。补上它是为了让"五份md5全一致"这条跨三方（开发第7节、dev卡点第11条、测试第4节）的契约在Node 0上真正可满足。

## 4. 单节点 vs 跨节点验证：为什么命令形态不同

- **单节点8卡**：在容器内跑，加`--mca plm isolated`，不依赖ssh。用于快速验证编译产物本身能跑通，不涉及跨节点通信路径。
- **跨节点32卡**：在宿主机跑，mpirun通过`-host`拉起4台节点的进程，依赖宿主机ssh互通。**容器内没有ssh，这一步不可能在容器内做。**
- 如果目标宿主机GLIBC版本与编译环境不匹配（`测试.md`提到Node 0系统为特定GLIBC版本），跨节点验证会不可用，此时**退回容器内单节点验证**作为替代手段——这是唯一能确认编译产物本身正确性的兜底路径。

## 5. SSH跳板拓扑

**规则：一律经`$MCCL_NODE0_IP`跳转。不要依赖直连。**

```bash
ssh root@$MCCL_NODE0_IP "ssh root@<目标节点> ..."
ssh root@$MCCL_NODE0_IP "scp <Node0上的路径> root@<目标节点>:<远程路径>"
```

理由有两条，第二条是关键：

1. `测试.md`记载部分节点需要经编译节点跳转才能到达，而经`$MCCL_NODE0_IP`跳转对**所有**节点都有效——它是唯一与全部节点连通的位置。选它没有例外情况要记。
2. **"能直连哪些节点"是agent运行位置的属性，不是节点的属性。**`测试.md`原文记的是"Windows直连60/57"——那是当时操作者工作站的网络位置。本工具包是可移植的，agent可能跑在任何一台机器上，照搬"某某节点可直连"会在别的位置直接失败。经跳板走则与agent位置无关。

这不是保守起见的建议，是`测试.md`的实际做法：分发`libmccl.so`到Node 1/2/3的三条`scp`命令（见第3节）**全部**经`$MCCL_NODE0_IP`发起，包括原文标注为可直连的那一台。附带的好处是编译产物本来就在Node 0上，从那里`scp`也最短。

因此`mccl-env.sh`不需要"哪台可直连"这类变量——按上面的规则走，这个信息用不上。

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

- **第3节的Node 0动作②（容器内`cp`到`$MCCL_MACA_LIB_DIR`）在`测试.md`里不存在**，是本文档补的（理由见第3节末尾）。它依据的两条事实都有原文出处——容器内`$MCCL_REMOTE_WORKDIR`与宿主机映射一致（bind mount）、跨节点mpirun的`LD_LIBRARY_PATH`指向`$MCCL_MACA_LIB_DIR`——但"因此Node 0要在容器内往这个目录`cp`一份"这个动作本身是推论，**（推断）**。原文缺这一步却能跑通的原因未记载，本文档不揣测。
- 第1节的引号层级解释是从bash引用规则推导的，`测试.md`只给出了命令的成品形态，没有解释为什么这么写。推导本身可自行验证。
- 第4节"GLIBC不匹配时退回单节点验证"中，"退回单节点验证"是`测试.md`明确给出的替代手段；但把它称为"唯一兜底路径"是本文档的判断，原文未如此表述。
