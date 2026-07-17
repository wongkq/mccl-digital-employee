# MCCL 编译陷阱

**读者**：开发agent。执行编译步骤前必读，尤其是改完代码却发现"改了跟没改一样"时先看第2条。

路径统一用`$MCCL_*`变量（定义见`mccl-env.sh`，模板见`mccl-env.sh.example`）。`/opt/maca`是MetaX MACA SDK的厂商标准安装路径，作为说明性上下文出现，不代表agent应该往这个路径写东西。

## 1. `MACA_PATH`两个版本，选错会导致跨节点句柄异常

MACA安装里`mcMemFabricHandle_t`结构体有两个版本：

- **正确版本**：1112字节，含scatter buffer。对应`$MCCL_MACA_PATH`。
- **错误版本**：80字节，旧版stub。常见于厂商默认安装路径`/opt/maca`。

编译时`MACA_PATH`必须指向`$MCCL_MACA_PATH`（含正确定义的那份），不能用厂商默认的`/opt/maca`。用错版本不会在编译期报错，而是在运行时表现为：**跨节点对称内存句柄异常、UDS Connection refused**。排查UDS连接被拒时，第一件事就是确认编译用的`MACA_PATH`指向了正确版本。

## 2. macaify增量编译陷阱（最隐蔽的坑）

改了`.cc`/`.h`文件后，**必须先`rm -rf build/macaify`再`make`**，否则编译产物用的是旧代码——而且不会报错，看起来"编译成功"，但改动其实没生效。

原因：macaify把源文件拷贝到`build/macaify/`目录（改名`.cu.cpp`后交给mxcc处理）用的是CMake的`copy_if_different`，这个机制不检测源文件时间戳变化，增量`make`不会触发重新拷贝。

标准增量编译流程：
```bash
cd $MCCL_REMOTE_SRC
rm -rf build/macaify
cd build && make -j50
```

**这是最容易踩的坑，会让人误以为改动没生效，转而怀疑代码逻辑本身出了问题**——遇到"改了但行为没变"时，先检查是不是漏了这一步，再去查代码逻辑。

## 3. 何时需要全量重编

只有以下两种情况才需要全量重编，其余情况用第2条的增量流程：

- `CMakeLists.txt`发生变更
- 编译出现异常（增量编译报出奇怪错误，怀疑是CMake缓存或依赖关系损坏）

全量重编：
```bash
cd $MCCL_REMOTE_SRC
rm -rf build && mkdir build && cd build
cmake -DCMAKE_CXX_COMPILER=$MCCL_MACA_PATH/mxgpu_llvm/bin/mxcc \
      -DCMAKE_INSTALL_PREFIX=$MCCL_MACA_PATH \
      -DUSE_SPLIT_KERNELS=ON \
      -DENABLE_CPACK=OFF ..
make -j50
```

## 4. mxcc报`__clang_maca_runtime_wrapper.h`找不到

原因：`$MCCL_MACA_PATH`下缺少`mxgpu_llvm/bin`（这份目录里才有实际的编译器二进制和runtime头文件），需要从厂商标准安装（`/opt/maca/mxgpu_llvm/bin`）建符号链接过去：

```bash
mkdir -p $MCCL_MACA_PATH/mxgpu_llvm/
ln -sf /opt/maca/mxgpu_llvm/bin $MCCL_MACA_PATH/mxgpu_llvm/bin
```

只需建一次，除非编译容器重建。

## 5. Kernel展开规模与编译时长

`cmake/Dependencies.cmake`里的`expand_collectives()`按（collective操作 × 规约op × 数据类型）展开成独立TU，约300+个translation unit（6个collective × 7个规约op × 12个数据类型，再减去无效组合）。每个`.cu`文件在编译时被复制到`build/macaify/`并改名为`.cu.cpp`，交给mxcc处理。

全量编译因为这个展开规模会比较慢，用`make -j50`（并发编译，见第3条的全量重编命令）。

## 6. 加快迭代的CMake选项

| 选项 | 作用 |
|---|---|
| `-DBUILD_ALLREDUCE_ONLY=ON` | 仅编译AllReduce kernel，跳过其余collective，大幅缩短编译时间。只改AllReduce相关代码时用 |
| `-DUSE_SPLIT_KERNELS=ON` | 拆分kernel编译。推荐常开，不是仅用于加速迭代的临时选项 |

`-DBUILD_ALLREDUCE_ONLY=ON`会跳过其他collective的编译产物，如果改动涉及AllReduce之外的操作，不要用这个选项，否则测试会因为找不到对应kernel而失败（这一点`测试.md`未明确给出失败表现，是本文档的推断——**（推断）**）。
