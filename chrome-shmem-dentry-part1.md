# Puppeteer 内存只涨不跌？--disable-dev-shm-usage 与 dentry 缓存（上篇：诊断）

> 这是一个两篇的系列。**上篇（本文）讲诊断**：内存去了哪里、为什么会这样。**下篇讲修复**。

这是一篇技术复盘。

我做了一个用无头浏览器（headless Chrome）打印 PDF 的服务，作为公共服务给各个业务方使用。上线一段时间后，发现它有疑似内存泄漏的现象：内存只涨不跌，最后只能靠重启解决。

最后调查得知：`--disable-dev-shm-usage` 让 Chrome 把共享内存建在 `/tmp` 上，产生的大量 dentry 撑大了可回收的 slab 缓存，又被算进了容器内存，看起来像内存泄漏，其实不是。

文中会用到不少操作系统和容器的术语，文末附了一份术语表，遇到不熟悉的词可以随时翻到最后查。文章最后还整理了一份内存增长的排查框架，以后再遇到"内存只涨不跌"或 OOM，可以直接照着走一遍。

## 序幕

> 出场人物：**Dev**、**SRE**。

**【镜头 1｜深夜，工位】**
告警群"叮"了一声。6 个 Pod 的内存曲线整整齐齐地往上爬。Dev 熟练地点下"重启"，曲线归零。
字幕：*这是本月第 N 次。*

**【镜头 2｜摇人】**
Dev 在群里 @SRE：「大佬，内存一直涨，帮忙看看？」
SRE 钻进 Pod，翻开 Chrome 进程的 `/proc/<pid>/fd`，满屏都是同一种东西：

```
297 -> '/tmp/.com.google.Chrome.IIWLkj (deleted)'
298 -> '/tmp/.com.google.Chrome.1aW5d2 (deleted)'
299 -> '/tmp/.com.google.Chrome.UWj4nM (deleted)'
...
```

SRE：「每个线程两千多个 fd，全指向 `/tmp` 下已经删掉的文件。」

**【镜头 3｜一条命令】**
SRE：「文件删了，内核还得给它们记账。看一眼 dentry：」

```
$ slabtop -o -s c | head
 OBJS      ACTIVE    USE   OBJ SIZE  SLABS  OBJ/SLAB  CACHE SIZE  NAME
 15927492  15927492  100%  0.19K     758452       21   3033808K   dentry
 806736    806736    100%  0.19K      38416       21    153664K   kmalloc-192
 547400    547186     99%  0.94K      16100       34    515200K   xfs_inode
 539826    539506     99%  0.19K      25706       21    102824K   xfs_ili
 425344    424323     99%  1.00K      13292       32    425344K   kmalloc-1k
```

**【镜头 4｜定案】**
SRE 指着第一行：「1590 万个 dentry，3 个 G。就是它。」
片尾字幕：*未完待续。*

下面是这个故事的"正片"。

## 现象

这个服务通过 Puppeteer 驱动一个 headless Chrome 把页面渲染成 PDF。它的内存在 Pod 的整个生命周期里单调上涨，直到告警响了，有人去重启它。

有意思的地方在于，这些内存几乎不属于任何一个进程。在一个跑了很久的 Pod 上执行 `slabtop`：

```
 OBJS      ACTIVE    USE   OBJ SIZE  SLABS  OBJ/SLAB  CACHE SIZE  NAME
 15927492  15927492  100%  0.19K     758452       21   3033808K   dentry
 806736    806736    100%  0.19K      38416       21    153664K   kmalloc-192
 547400    547186     99%  0.94K      16100       34    515200K   xfs_inode
 539826    539506     99%  0.19K      25706       21    102824K   xfs_ili
 425344    424323     99%  1.00K      13292       32    425344K   kmalloc-1k
```

> **怎么读这张表**：每一行是一种内核对象的 slab 缓存。`OBJS` 是对象总数，`ACTIVE` 是正在使用的数量，`OBJ SIZE` 是单个对象大小，`CACHE SIZE` 是这种对象总共占的内存。以第一行为例，约 1590 万个 dentry × 0.19K ≈ 3GB。

3GB 的 `dentry`，外加半个 G 的 `xfs_inode` 和 100MB 的 `xfs_ili`。这些都是内核 slab 缓存，属于 VFS（虚拟文件系统层）的元数据。说明有东西在疯狂建文件。

看一眼 Chrome 浏览器进程的 `/proc/<pid>/task/<tid>/fd`，答案就出来了：

```
lr-x------ 1 root root 64 Jun 20 17:29 297 -> '/tmp/.com.google.Chrome.IIWLkj (deleted)'
lr-x------ 1 root root 64 Jun 20 17:29 298 -> '/tmp/.com.google.Chrome.1aW5d2 (deleted)'
lr-x------ 1 root root 64 Jun 20 17:29 299 -> '/tmp/.com.google.Chrome.UWj4nM (deleted)'
lr-x------ 1 root root 64 Jun 20 17:29   3 -> /opt/google/chrome/icudtl.dat
lr-x------ 1 root root 64 Jun 20 17:29 300 -> '/tmp/.com.google.Chrome.TUBeqR (deleted)'
...
```

每个线程两千多个 fd，几乎全部指向 `/tmp` 下**已经被删除**的文件。另外注意同一个名字会出现多次（`1aW5d2` 在 fd 298 和 302，`pP9Tk0` 在 303 和 307）：一个文件，多个描述符。

接下来两节回答两个问题：这些文件是什么，以及为什么"已删除"的文件仍然要吃内核内存。

## 一、/tmp/.com.google.Chrome.XXXXXX 到底是什么

Chrome 是多进程浏览器。浏览器主进程、各个 renderer、GPU 进程和各种 utility 进程之间需要传递大块 buffer：渲染出来的 tile、解码后的图片、视频帧、可转移的 `ArrayBuffer`、页面合成层的后备存储。走 IPC 管道拷贝这些数据代价高到不可接受，所以 Chrome 用**共享内存**：同一块物理内存同时映射进两个或多个进程。

在 Linux 上，拿到一块匿名共享内存的通用做法是：

1. 在一个以内存为后备的文件系统里建一个文件；
2. 立刻 `unlink()`，不留下任何名字；
3. 保留文件描述符并 `mmap()` 它；
4. 通过 UNIX socket（`SCM_RIGHTS`，一种在进程间传递 fd 的机制）把这个描述符传给对端进程；
5. 双方 `mmap()` 同一个描述符，于是共享了同一批物理页。

第 2 步是让这块区域"匿名"的关键：没人能按名字打开它，不会有命名冲突，最后一个进程退出时内核会自动回收。这也正是 `/proc/<pid>/fd` 里显示 `(deleted)` 的原因：文件已经没有名字了，但描述符依然指向它。

Chrome 里负责第 1 步的辅助函数会挑一个目录。默认挑的是 `/dev/shm`，在任何正常的 Linux 系统上它都是一个 tmpfs。而一旦传了 `--disable-dev-shm-usage`，它就退回去用常规临时目录，也就是 `/tmp`。

我们的服务恰好传了这个 flag（`src/config/config.default.ts`）：

```ts
'--disable-dev-shm-usage',
```

于是 Chrome 每分配一块共享内存，就变成**在 `/tmp` 里建一个文件**：创建、unlink、然后在这块区域存活期间一直持有它。上面那串 fd 列表就是这么来的。

### 这个 flag 当初为什么会被加上

它不是什么低级错误，几乎每一篇"在 Docker 里跑 Chrome"的教程都会加，而且理由很充分：Docker 默认给容器的 `/dev/shm` 只有 **64MB**，Kubernetes 从运行时继承了这个默认值。Chrome 渲染内容稍微重一点的页面就会把 64MB 撑爆，而共享内存分配失败的表现就是那些经典故障：renderer 崩溃、`Target closed`、`Page crashed`、`Protocol error`、高负载下 PDF 任务随机失败。

`--disable-dev-shm-usage` 把分配引到 `/tmp`，背后是整个容器文件系统而不是 64MB，崩溃就消失了。**它用一个慢性泄漏换掉了一个硬崩溃。** 我们一直在付这笔交易的后半部分。

## 二、为什么删掉的文件还在占内存

先简单回顾两个概念（文末术语表有更详细的解释）：**inode** 是文件本身，缓存在各文件系统自己的 slab 里（XFS 是 `xfs_inode`，tmpfs 是 `shmem_inode_cache`）；**dentry** 是路径里的一个组成部分，一个绑定到 inode 的 `{父目录, 名字}` 对，放在 dcache 里。任何进程每解析一次 `/tmp/.com.google.Chrome.IIWLkj`，内核就要走 `/` → `tmp` → `.com.google.Chrome.IIWLkj`，每一级都对应一个 dentry。

那么 `unlink()` 到底做了什么？

```
unlink("/tmp/.com.google.Chrome.IIWLkj")
   │
   ├─ inode->i_nlink-- ............ 1 → 0（再没有名字指向这里了）
   │
   ├─ 还有人在用这个 inode 吗（i_count > 0）？
   │     有 → inode 保留，数据保留，页也保留。
   │           只有最后一个 fd 关闭时才会被释放。
   │
   └─ 还有人持有这个 dentry 吗？
         有 → dentry 被取消哈希（d_drop），新的路径查找再也找不到它，
               但它不会被释放 —— 一个打开的文件持有着对它的引用。
```

> `i_nlink` 是指向这个 inode 的名字数量（硬链接数），`i_count` 是内核里对这个 inode 的引用计数。名字数为 0 只代表"找不到了"，引用计数为 0 才代表"可以释放了"。

最后这一行就是全部的关窍。一个打开的 fd 背后是 `struct file`，`struct file` 里有 `f_path`，`f_path` 里有一个指向 **dentry** 的指针。所以一个打开的 fd 同时钉住了 inode 和 dentry。这也正是内核有能力在 `/proc/<pid>/fd` 里打印出 `/tmp/.com.google.Chrome.IIWLkj (deleted)` 的原因：它是顺着被钉住的 dentry 链往上走重建出这个名字的。

于是，在容器内部，每一块存活的共享内存区域对应：

| 对象 | slab | fd 打开期间是否被钉住 |
| --- | --- | --- |
| 临时文件名对应的 dentry | `dentry` | 是 |
| inode | `xfs_inode`（外加记 inode 日志项的 `xfs_ili`） | 是 |
| `struct file`（每个描述符一个） | `filp` | 是 |
| 页本身 | page cache | 是 |

乘以几千块存活区域，slabtop 里的 `filp`、`xfs_inode`、`xfs_ili` 就都对上了。

### 但 1590 万个 dentry 远远超过 fd 的数量

没错，这一点值得说准。被 fd 钉住的 dentry 大概在几万这个量级，不是百万级。3GB 的 `dentry` 主要来自 **churn（创建/销毁的流水）**，而不是此刻被钉住的那些。

dcache 是个**缓存**。它会机会性地增长，只有在内存压力下才会被裁剪。一个进程在几小时里创建并销毁几百万条短命路径，就会留下一个巨大的 dcache，而只要节点还有空闲内存，就没有任何东西会去缩它。这是设计如此，不是 bug。

有两件事让这些 churn 比看上去贵得多：

- **容器里的 `/tmp` 通常就是 overlayfs 的可写层**，而不是一个普通文件系统。在那里建一个文件，会在 overlay 里分配一个 dentry，同时在底层文件系统（这里是 XFS）里分配 dentry 加 inode。一个逻辑文件，好几个内核对象。这和 slabtop 里同时看到 `dentry`、`xfs_inode`、`xfs_ili` 并列靠前是吻合的。
- 我们的配置还把 Chrome 的磁盘缓存也指向了 `/tmp`（`--disk-cache-dir=/tmp/puppeteer`），在同一个文件系统上又叠了一层自己的创建/淘汰流水。

另外别忘了 `slabtop` 看到的是**整个节点**的 slab，其中可能也有同节点其他 Pod 的贡献。

我们没有在内核里插桩去把这 1590 万个 dentry 逐条归因到具体路径，在产线 Pod 上这么做代价太大，所以我们停在了一个有把握的诊断，而不是一个完整的诊断。有直接证据支撑的是**机制**：Chrome 的共享内存分配落在了一个磁盘后备、overlay 挂载的 `/tmp` 上，被钉住的对象和那些 churn 都是这个事实的推论。

### 为什么它会告警但不会崩

`dentry` 和各种 `*_inode` slab 都是**可回收的**。它们计在 `/proc/meminfo` 的 `SReclaimable` 里，内存一紧张，内核会先去缩它们，根本轮不到 OOM kill。所以服务从来没有真正处于危险中。

问题出在计量上。一个 cgroup 的内存用量，也就是仪表盘和 HPA（Kubernetes 的水平自动扩缩容）读的 `container_memory_working_set_bytes`，包含了记在这个 cgroup 上的内核 slab，可不可回收都算。于是曲线一路上涨，告警响个不停，而实际上什么事都没有。

## 小结与下篇预告

把上面的链条串起来：

1. 为了躲开 Docker 默认 64MB 的 `/dev/shm`，服务给 Chrome 加了 `--disable-dev-shm-usage`；
2. Chrome 因此把每一块共享内存都建成 `/tmp` 里的一个临时文件，建完立刻删名字、继续持有；
3. 容器的 `/tmp` 落在 overlayfs + XFS 上，每个文件都要内核记好几份元数据（dentry、`xfs_inode`、`xfs_ili`）；
4. 打开的 fd 钉住了一部分对象，大量创建/销毁又把 dcache 撑得很大；
5. 这些 slab 可回收，所以服务从未真正危险，但它们计入了容器内存，于是曲线只涨不跌，告警一直响。

这给了我们两个相互独立的抓手，而且它们修的是不同的东西：

- **不再产生这些对象**：内存曲线不再上涨（真正的修复）
- **告警不再统计可回收 slab**：告警不再说谎（诚实的指标）

下篇会讲具体怎么做：给 Pod 配一个尺寸合适的 `/dev/shm` 并去掉那个 flag，为什么换到 tmpfs 真的有区别、要付出什么代价；在应用层定期回收浏览器，把内存曲线从斜坡变成锯齿；以及如何让监控不再为一个可回收的内核缓存报警。

**下篇：[Puppeteer 内存只涨不跌？--disable-dev-shm-usage 与 dentry 缓存（下篇：修复）](./chrome-shmem-dentry-part2.md)**

## 参考资料

- 阿里云文档：[如何排查 slab_unreclaimable 内存占用高的原因](https://www.alibabacloud.com/help/zh/alinux/support/identify-the-causes-of-high-percentage-of-the-slab-unreclaimable-memory)

## 附录：术语与概念

下面这些术语按"从底层往上"的顺序排列，后一个通常会用到前一个。

### 内核、用户态与系统调用

"内核"指操作系统内核，这里就是 **Linux 内核**。它是操作系统最底层的核心，负责管理内存、调度 CPU、管理文件系统和网络。

我们平时写和运行的程序（Chrome、Node.js、`ls`）都跑在**用户态**，不能直接碰硬件。它们想建文件、分配内存，都要通过**系统调用**请内核代劳，比如 `open()`、`unlink()`、`mmap()`。

可以把内核想成大楼的物业：住户（程序）要用水电、开新房间都得找物业，物业自己还要维护各种登记簿。本文讲的那 3GB 内存，就是物业的登记簿，不是住户的家当。

### Pod 与容器

**容器**是用 Linux 内核的隔离机制打包起来的一组进程，看起来像一台独立的小机器，但和同一台机器上的其他容器**共享同一个内核**。**Pod** 是 Kubernetes 调度的最小单位，里面装一个或几个容器。

"共享同一个内核"这一点很重要：容器里看到的部分内核信息其实是整台机器（节点）的，正文讲 `slabtop` 时提到过这一点。

### 文件描述符（fd）

进程打开一个文件后，内核返回一个小整数，叫**文件描述符**（file descriptor，简称 fd）。之后进程用这个数字来读写文件。每个进程打开的 fd 列在 `/proc/<pid>/fd` 下面，每一项是一个指向实际文件的符号链接。

在内核里，每个 fd 背后是一个 `struct file` 对象，记录"这个文件被谁、以什么方式打开"。

### inode

**inode** 代表"文件本身"：大小、权限、数据存放在哪里。每个文件一个 inode。

注意，**inode 里没有文件名**。文件名存在别处，也就是下面要讲的 dentry。

### dentry 与 dcache

**dentry**（directory entry，目录项）是"名字 → inode"的一条对应关系。目录本质上就是一张这样的对照表。

打个比方：inode 是一个人，dentry 是通讯录里的一条记录"张三 → 这个人"。同一个人可以有多条记录（硬链接）；把记录划掉，人还在。

内核访问 `/tmp/foo` 时，要逐级查找：根目录里找 `tmp`，`tmp` 里找 `foo`。每一级的查找结果都会缓存成一个 dentry 对象，下次就不用重新查磁盘了。这个缓存整体叫 **dcache**。它会尽量长大，只有在内存紧张时才被裁剪。

### slab 缓存与 slabtop

内核要频繁创建和销毁大量同类型、固定大小的小对象：dentry、inode、`struct file` 等。**slab 分配器**为每种对象开一个专用"仓库"：预先申请几页内存，切成大小正好的格子，要用时拿一格，释放时标记为空闲，留着下次复用。

slab 是 **Linux 内核自己的机制**，和 Chrome 无关。任何程序大量建文件，都会让 slab 涨起来；Chrome 在本文里只是触发者。

slab 里的对象有一部分是**可回收的**（比如 dentry、inode 缓存，丢了只是下次要重新查），计在 `/proc/meminfo` 的 `SReclaimable` 里，内存紧张时内核会主动收缩它们。

**`slabtop`** 是查看 slab 的命令行工具，相当于"专门看 slab 的 `top`"。它读取 `/proc/slabinfo`，列出每种对象的数量、单个大小和总占用。需要注意：`/proc/slabinfo` **不按容器隔离**，在 Pod 里看到的是整个节点的总量。

### 共享内存与 mmap

**共享内存**是让两个或多个进程映射同一块物理内存，一方写入另一方立刻可见，不需要拷贝数据。`mmap()` 是把一个文件（或一块内存）映射进进程地址空间的系统调用。

Chrome 是多进程浏览器，主进程、渲染进程、GPU 进程之间要传大量图片和画面数据，所以重度依赖共享内存。

### tmpfs 与 /dev/shm

**tmpfs** 是一种完全活在内存里的文件系统，没有磁盘，没有日志，重启即消失。在上面建文件，内容直接就是内存页。

**`/dev/shm`** 是 Linux 约定俗成的共享内存目录，通常挂载为 tmpfs。Docker 默认只给容器的 `/dev/shm` **64MB**，Kubernetes 也沿用了这个默认值。

### overlayfs

**overlayfs** 是容器文件系统的常见实现：把只读的镜像层和一个可写层叠在一起，让容器看到一个完整的目录树。容器里新建的文件实际写在可写层，而可写层又落在宿主机的磁盘文件系统上（本文里是 **XFS**）。

所以在容器的 `/tmp` 里建一个文件，内核要同时为 overlay 层和底层 XFS 各记一份元数据。

### cgroup 与容器内存计量

**cgroup** 是 Linux 用来给一组进程分配和限制资源的机制，容器的 CPU、内存限额就是靠它实现的。

容器的内存用量（监控里常见的 `container_memory_working_set_bytes`）不只包含进程自己的内存，**还包含记在这个 cgroup 上的内核 slab**，可回收的也算在内。这就是本文中"服务没事，告警却一直响"的根本原因。

## 附：内存增长排查框架（以本案为例）

这次排查最后找到了根因，但过程里走过的弯路和没走的路同样有价值。这一节把 Dev 和 SRE 的思路整理成一个分层框架，再用本案的真实对话走一遍，方便以后遇到内存上涨或 OOM 时照着查。

### 1. 先定性：要不要查、查哪个数

动手之前先回答三个问题，很多时候答完就知道该往哪一层走：

- **真的 OOM 了吗？** `kubectl describe pod` 看 `Last State` 是不是 `OOMKilled`（退出码 137）。没 OOM 过，说明问题可能在"告警"而不在"服务"。
- **涨的是哪个数？** `container_memory_usage_bytes`、`container_memory_working_set_bytes`、进程 RSS 三者对不对得上。对不上，多出来的部分就不在进程身上。
- **曲线是什么形状？** 一路斜坡、锯齿（涨了会自己回落）还是台阶式跳变？跟流量走还是跟时间走？斜坡且不随流量回落，通常指向累积型的缓存或泄漏。

### 2. 分层排查：从上往下逐层排除

```
           内存曲线上涨
                │
     L0 cgroup memory.stat：涨在哪个桶？
       ┌────────┼──────────────┬──────────────┐
      anon    file/shmem    slab_reclaimable  slab_unreclaimable
       │        │                │                 │
   L1 进程 RSS  L3 文件/fd     L4 slabtop       L4 内核泄漏排查
   L2 应用堆   /tmp、/dev/shm  看是哪种对象      （kmemleak 等）
       │        │                │                 │
       └────────┴───────┬────────┴─────────────────┘
                        │
              L5 测试环境复现 + 验证
```

| 层 | 看什么 | 命令 | 怎么读 |
| --- | --- | --- | --- |
| L0 cgroup | 内存涨在哪个桶 | cgroup v2：`cat /sys/fs/cgroup/memory.stat`；v1：`cat /sys/fs/cgroup/memory/memory.stat` | 关注 `anon`、`file`、`shmem`、`slab_reclaimable`、`slab_unreclaimable`、`sock`。v1 较老的内核没有 slab 字段，只能退到 L4 看全局 |
| L1 进程 | 内存是不是在某个进程身上 | `ps aux --sort=-rss`；`/proc/<pid>/status`（`VmRSS`、`RssAnon`、`RssFile`、`RssShmem`）；`/proc/<pid>/smaps_rollup` | 所有进程 RSS 加起来远小于容器 usage，说明多出来的不属于进程，往 L3/L4 走 |
| L2 应用 | 应用自己有没有泄漏 | Node：`process.memoryUsage()`（`heapUsed`、`external`、`arrayBuffers`）、heap snapshot；Puppeteer：未关闭的 page / browserContext、越积越多的 listener；Chrome 子进程数量、僵尸进程 | 堆持续上涨才是应用泄漏；堆平稳就别在这层花时间 |
| L3 文件 / fd | 有没有大量打开或"删了但没关"的文件 | `ls /proc/<pid>/fd \| wc -l`；`ls -l /proc/<pid>/fd \| grep deleted`；`lsof +L1`；`du -sh /tmp`；`df -h /dev/shm` | 大量 `(deleted)` 说明有文件名删了、内核对象还在；tmpfs 写满会算进 `shmem` |
| L4 内核 | 内核对象（slab）是不是在涨 | `grep -e Slab -e SReclaimable -e SUnreclaim /proc/meminfo`；`slabtop -o -s c \| head`；`/proc/slabinfo` | 先分清可回收（`SReclaimable`，如 dentry、inode）还是不可回收（`SUnreclaim`）。注意 slabinfo 是整个节点的数 |
| L5 验证 | 结论站不站得住 | 测试环境复现；`echo 2 > /proc/sys/vm/drop_caches` 看曲线是否回落；去掉可疑 flag / 配置做 A/B | 能回落说明是可回收缓存，不是泄漏；A/B 对比能把机制和现象对上 |

两点提醒：

- 如果落在 `slab_unreclaimable`，那才是真正需要担心的内核内存泄漏。阿里云这篇[《如何排查 slab_unreclaimable 内存占用高的原因》](https://www.alibabacloud.com/help/zh/alinux/support/identify-the-causes-of-high-percentage-of-the-slab-unreclaimable-memory)讲了 kmemleak、跟踪 kmalloc 调用点等方法，但这些工具在产线上代价很大，最好在测试环境做。
- `drop_caches` 作用于整个节点，而且需要特权，只在测试环境或自己独占的节点上用。

### 3. 本案走查

下面是原汁原味的问答（措辞略作整理），每条标上它落在框架的哪一层，后面附一句"回头看"：知道答案以后，再看当时那句话说对了什么、错过了什么。

一句话概括本案的路径：Q2 在 L1 发现 RSS 和 usage 对不上，直接跳过了 L2；Q4、Q5 落到了 L3 的 `(deleted)` 文件；之后顺势进入 L4，用 `slabtop` 看到了 dentry（序幕里那张表）；再往下做逐条路径归因时，卡在了"工具难在产线跑"，于是约到测试环境继续（L5）。

**Q1｜Dev 开口求助** · 先定性 / L1 进程层

> Dev：Hi 大佬，能帮忙进到这个实例里，打印一下容器里各个进程的内存占用吗？内存一直在涨。

回头看：一开口就提了具体请求（进实例、看各进程内存），而不是只说一句"帮忙看看"。

**Q2｜Dev 给出关键线索** · L1 进程层

> Dev：我看服务的 RES 其实没这么大，RSS 只有几百 M，但监控上的 usage 有 2–3 个 G。可能是 mmap 之类的导致的，不一定是我们服务本身的问题。

回头看：这是整次排查最有价值的一句：RSS 和 usage 对不上，说明多出来的内存不在进程身上。

**Q3｜SRE 问调用面** · L2 应用层 → L3

> SRE：这个服务有什么系统调用？
>
> Dev：服务里跑了一个浏览器，相当于浏览器会去调用各种系统功能。

回头看：SRE 想从系统调用这一层找线索，最后的根因也确实在这一层（Chrome 创建并 unlink 共享内存文件）。

**Q4｜SRE 发现 fd** · L3 文件 / fd 层

> SRE：每个线程目前打开了 2000 多个 fd，大概有二三十个线程。
>
> Dev：fd 是正常的，相当于一个页面会有很多请求。

回头看：fd 的数量也许正常，但它们全指向 `/tmp` 下的 `(deleted)` 文件，这一点不正常。

**Q5｜SRE 怀疑临时文件** · L3 文件 / fd 层

> SRE：基本可以确定，是这些文件导致的。
>
> Dev：应该不是吧，这本来就是临时文件。
>
> SRE：确实没法确定具体是哪些 path，目前只是猜测。

回头看：SRE 的直觉是对的。临时文件也要内核记账（dentry / inode）。

**Q6｜Dev 提到那个 flag** · L3 → L4

> Dev：我们加了 `--disable-dev-shm-usage`，本来是写文件的，禁用后就是写完就删除了。
>
> SRE：是什么场景写文件？跟文件数量有关系吗？
>
> Dev：服务端会跑一个浏览器去渲染页面，浏览器机制很复杂，有很多缓存策略，网络请求会触发缓存，从内存再到 disk。

回头看：根因就在这条 flag 里。删掉的是文件名，内核里的对象还在；而且这些文件是 Chrome 的共享内存，不是网络缓存。

**Q7｜SRE 给出结论** · 先定性（会不会 OOM）

> SRE：现有工具没法再往下查了，成本比较大。结论是内存上涨由频繁的文件打开/遍历导致。这块内存应该不会导致 OOM，目前没遇到过 OOM 吧？
>
> Dev：没有。不过内存一直涨，就会一直告警。

回头看：这里把问题拆成了两个：会不会 OOM（不会）和要不要告警（会）。下篇的两个修复方向就是从这里来的。

**Q8｜Dev 递上参考资料** · L4 内核层

> Dev：这篇[排查 slab_unreclaimable 内存占用高的文档](https://www.alibabacloud.com/help/zh/alinux/support/identify-the-causes-of-high-percentage-of-the-slab-unreclaimable-memory)，有参考价值吗？
>
> SRE：这些工具比较难在产线运行。其实主要还是找另一个指标替换这个内存指标，因为这块内存实际上可以回收，不会影响服务。

回头看：dentry 属于 SReclaimable（可回收），和文档讲的 unreclaimable 不是一类；"换指标"的建议也成了下篇的修复方向之一。

**Q9｜收尾** · L5 验证

> Dev：明天在测试环境复现一下，到时候帮忙一起看看。

回头看：产线不方便插桩，就把排查挪到测试环境去做。

### 4. 排除过的和没走的方向

本案真正排查并排除的只有 Node 堆内存这一条，其余方向当时没有做，列在这里是为了下次遇到类似问题时不漏掉。

| 方向 | 所在层 | 本案情况 | 说明 |
| --- | --- | --- | --- |
| Node 堆内存泄漏 | L2 | **已排除** | 服务 RSS 只有几百 MB，远小于监控上的 2–3GB，堆不是大头 |
| Chrome 残留 / 僵尸进程 | L2 | 本案未做，可补做 | `ps` 数一下 Chrome 进程数量是否随时间增长；Puppeteer 没关干净的 browser 会留下整棵进程树 |
| `--disk-cache-dir=/tmp/puppeteer` 的 page cache | L0 / L3 | 本案未做，可补做 | 看 `memory.stat` 里的 `file` 是否在涨、`du -sh /tmp/puppeteer` 有多大 |
| `/dev/shm` tmpfs 占用 | L3 | 本案未做（加了 flag 后基本不用 `/dev/shm`） | 去掉 flag 之后要重点看：tmpfs 里的数据算在 `shmem`，是实打实的内存 |
| slab_unreclaimable / 内核泄漏 | L4 | 不适用 | dentry 属于可回收的 `SReclaimable`，和这类问题不是一回事 |
| 同节点其他 Pod 的贡献 | L4 | 本案未做，可补做 | `slabtop` 是节点全局视角；要确认归属，看本 cgroup 的 `memory.stat` 里的 slab 字段 |
| `drop_caches` 验证可回收 | L5 | 本案未做，可补做 | 在测试环境执行后曲线回落，就能直接证明"可回收、不是泄漏" |

### 5. 下次可以直接抄的清单

1. 有没有 OOMKilled？没有的话，先怀疑指标而不是服务。
2. usage、working_set、RSS 三个数对得上吗？
3. `memory.stat`：涨在 anon、file、shmem 还是 slab？
4. anon 涨：看进程 RSS 和应用堆（L1、L2）。
5. file / shmem 涨：看 `/tmp`、`/dev/shm`、磁盘缓存目录（L3）。
6. slab 涨：`slabtop -o -s c`，分清 reclaimable 还是 unreclaimable（L4）。
7. fd 里大量 `(deleted)`：找出是谁在"建完就删、继续持有"。
8. 结论拿到测试环境复现，用 `drop_caches` 或 A/B 对比验证（L5）。
