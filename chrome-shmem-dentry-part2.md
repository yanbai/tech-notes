# Puppeteer 内存只涨不跌？--disable-dev-shm-usage 与 dentry 缓存（下篇：修复）

给 Pod 一个真正的 `/dev/shm`，定期回收浏览器，再让告警只看真正会导致 OOM 的那部分内存。三层修复互不依赖，可以叠加。

> 这是一个两篇的系列。上篇讲诊断，**下篇（本文）讲修复**。上篇：[Puppeteer 内存只涨不跌？--disable-dev-shm-usage 与 dentry 缓存（上篇：诊断）](./chrome-shmem-dentry-part1.md)

**前情提要**：笔者做的 PDF 打印服务用 headless Chrome 渲染页面。为了躲开 Docker 默认只有 64MB 的 `/dev/shm`，服务给 Chrome 加了 `--disable-dev-shm-usage`。于是 Chrome 把每一块共享内存都建成了 `/tmp` 里的临时文件，而容器的 `/tmp` 落在 overlayfs + XFS 上，内核为这些文件记下了海量 dentry 和 inode 元数据。这些 slab 虽然可回收，却被计入了容器内存，于是曲线只涨不跌，告警一直响。

上篇最后提到两个相互独立的抓手：**不再产生这些对象**，以及**告警不再统计可回收 slab**。本篇按三个层次展开：

1. 基础设施层：给 Pod 配 `/dev/shm`，去掉那个 flag（第一到第四节）；
2. 应用层：定期回收浏览器（第五节）；
3. 可观测性层：调整告警指标（第六节）。

本篇新出现的术语同样放在文末附录。

## 一、方案：给 Pod 一个真正的 /dev/shm

方案是去掉 `--disable-dev-shm-usage`，同时给 Pod 一个尺寸合适的 `/dev/shm`：

```yaml
spec:
  containers:
    - name: pdf-renderer
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 1Gi
```

`emptyDir` 加上 `medium: Memory`，是在告诉 kubelet 在这个路径上挂一个 tmpfs，而不是从节点磁盘上划一个目录。`sizeLimit` 给它封顶。没有这段配置，容器拿到的就是运行时默认的 64MB `/dev/shm`，这正是当初要加那个 flag 的全部原因。

**两件事必须一起做**：

- 只去掉 flag、不配 `/dev/shm`：会把崩溃原样放回来；
- 只配 `/dev/shm`、不去掉 flag：Chrome 根本不会用它。

## 二、为什么换到 tmpfs 真的有区别

一个很合理的质疑：tmpfs 上的文件也有 dentry 和 inode 啊，凭什么比 `/tmp` 好？

**1. 没有 overlayfs，没有重复记账。** `/dev/shm` 作为 tmpfs 挂载点，是一个独立的文件系统，直接挂在容器的 mount namespace 上。那里的一个文件就是一个 `shmem_inode_cache` inode 加一个 dentry。同样一个文件放在 overlay 挂载的 `/tmp` 上，要花掉一个 overlay dentry，加上底层文件系统的 dentry、一个 `xfs_inode`、一个 `xfs_ili` 日志项。同样的负载，内核对象少掉一大截，而且最重的那几个（0.94K 一个的 `xfs_inode`，还有 `xfs_ili`）直接消失了。

**2. 不再为一次性文件付磁盘文件系统的成本。** 在磁盘后备的文件系统上，文件内容活在 page cache 里，文件系统还要为它们维护块映射、extent 树和日志项。`xfs_ili` 字面意思就是 XFS inode log item 的 slab，它存在的唯一原因是 XFS 在给一批永远不会被读回、也活不过一次重启的文件记元数据日志。而在 tmpfs 上，页本身就是存储：没有块分配器，没有日志，没有回写路径。把共享内存放在 RAM 文件系统上，本来就是这套机制被设计出来时的用法。

**3. 它是有界的，而且一眼可见。** tmpfs 的用量可以直接看（`df -h /dev/shm`），并由 `sizeLimit` 封顶。而现状是完全没有天花板的，一路涨到 Pod 被重启为止。

| 对比项 | 现状：`/tmp`（overlayfs + XFS） | 方案：`/dev/shm`（tmpfs） |
| --- | --- | --- |
| 每个文件的内核对象 | overlay dentry + XFS dentry + `xfs_inode` + `xfs_ili` | 一个 dentry + 一个 `shmem_inode_cache` |
| 元数据日志 | 有（XFS journal） | 无 |
| 用量上限 | 无，涨到重启为止 | `sizeLimit` 封顶 |
| 用量观察 | 混在 slab 里，难以归因 | `df -h /dev/shm` 直接看 |

## 三、它做不到什么，以及要认的代价

- **tmpfs 不是白送的内存。** `medium: Memory` 的 emptyDir 里的页会记在 Pod 的 memory cgroup 上，计入它的 limit，而且和可回收 slab 不同，内核不能随手把它们丢掉。你是把共享内存从"磁盘后备的文件页 + 一堆 XFS 元数据"挪成了"tmpfs 页，老老实实地计量"。容器的 memory limit 必须在正常用量之外留出 `sizeLimit` 的余量，否则就是把误告警换成了真正的 OOM kill。**先定 limit，再定卷的大小。**
- **`sizeLimit` 的强制执行依赖 kubelet 版本。** memory-backed emptyDir 的尺寸限制在 GA 之前有好几个版本是藏在 `SizeMemoryBackedVolumes` feature gate 后面的。在老集群上 `sizeLimit` 可能只是个建议值，那种情况下一个失控的 Chrome 能一路吃到 Pod 的 memory limit。落地前先确认集群版本。
- **它不会缩掉已经涨起来的 dcache。** 它只是停止继续喂。已有的 slab 要靠内核在内存压力下回收，或者等下一次 Pod 重启。
- **尺寸很关键，而且这是唯一有风险的部分。** 64MB 太小，这正是那个 flag 存在的原因。headless 渲染场景的常见区间是 256MiB–1GiB；我们的页面面向打印、图片很大，所以从 1GiB 起步，在真实流量下盯 `df /dev/shm`，之后再收紧。如果去掉 flag 却没有配好 `/dev/shm`，就会把这个 flag 当初压下去的 renderer 崩溃原样放回来，这是灰度时要重点盯的失败模式：`Target closed`、`Page crashed`、PDF 任务失败率。
- **新版 Chrome 在部分环境下可以完全不碰文件。** 在 `memfd_create(2)` 可用、且沙箱 / seccomp 策略允许的环境下，Chromium 有能力把共享内存分配成匿名 memfd，不产生任何文件系统路径。我们的 fd 列表里全是有名字的 `/tmp` 文件，说明这条路径没被走到，显式的 `--disable-dev-shm-usage` 回退把它盖掉了。去掉这个 flag，也是让 Chrome 有机会用上更便宜的机制的前提。

## 四、动手改之前先验证

上面关于 overlayfs 的判断应该在真实 Pod 上确认，而不是假定。有些部署已经往 `/tmp` 上挂了 emptyDir，那成本模型就不一样了：

```bash
# /tmp 实际落在什么文件系统上？
df -hT /tmp
mount | grep -E ' /tmp | /dev/shm '

# /dev/shm 现在多大，用了多少？
df -h /dev/shm

# Chrome 主进程（最早启动的那个）持有多少 fd，其中多少是已删除的 /tmp 文件？
chrome=$(pgrep -o -f 'chrome.*--headless')
ls /proc/$chrome/fd | wc -l
ls -l /proc/$chrome/fd | grep -c 'tmp/.com.google.Chrome.*deleted'

# 本容器 cgroup 的内存分桶（cgroup v2）
grep -E '^(anon|file|shmem|slab|slab_reclaimable|slab_unreclaimable) ' /sys/fs/cgroup/memory.stat

# 节点视角的 slab 全景
grep -E '^(SReclaimable|SUnreclaim|Slab)' /proc/meminfo
slabtop -o -s c | head -12
```

改完之后，应该看到：

- `xfs_inode` / `xfs_ili` 从 `slabtop` 顶部掉下去；
- 指向已删除 `/tmp` 文件的那些 fd 变成指向 `/dev/shm`（或者干脆消失，如果 Chrome 切到了 memfd）；
- `memory.stat` 里 `slab_reclaimable` 不再单调上涨，`shmem` 开始有读数，并且和 `df -h /dev/shm` 的已用量大致对得上。

别忘了上篇提过的一点：`slabtop` 和 `/proc/meminfo` 看到的是**整个节点**的数据。要确认这个 Pod 自己的变化，更可靠的是看它所在 cgroup 的 `memory.stat` 里的 slab 字段，或者对比修改前后同一节点上的趋势。

## 五、先落地的那一层：定期回收浏览器

`/dev/shm` 的改动需要动部署配置，往往要和基础设施团队配合。有一个完全可以在应用代码里落地的修复，它打的是机制的另一半：**浏览器是一个永不重启的单例。**

服务在启动时拉起 Chrome，此后只有在 `disconnected` 事件上被动重建。配合单 worker，就是一个 Pod 一个 Chrome 进程，从 Pod 启动活到 Pod 死亡。它这辈子分配过、还没释放的每一块共享内存都还被钉着。**累积窗口等于 Pod 的生命周期。**

把这个窗口缩短，是一个一句话就能说清、效果也很直白的办法：每 N 次渲染（或每 T 分钟）关掉浏览器，再拉起一个新的。进程一退出，它持有的所有描述符全部关闭，所有被钉住的 dentry 和 inode 全部释放，内存曲线就从斜坡变成锯齿。

实现刻意写得很无聊，要点有四个：

- **计数**：一个进程级的已完成渲染计数器，加上浏览器的启动时间；
- **闸门**：一旦到期，新进来的渲染先等回收完成，而不是打到一个正在被拆掉的浏览器上；
- **排空**：闸门关上之后，等已经在途的请求全部做完再关浏览器，保证不会有请求正握着一个 page。注意，如果只是"碰到在途数为 0 时才回收"，在持续有并发的情况下在途数可能永远到不了 0，回收就永远不会发生，所以要先关闸门、再等排空；
- **不外溢**：在 PDF 已经产出之后才考虑回收，并且绝不让回收失败以请求错误的形式冒出来。浏览器没能关掉或起不来，是回收和重建逻辑要操心的事，不是调用方的事。

下面是一个简化的示意（基于较新版本的 Puppeteer，省略了日志、配置读取、超时处理和已有的 `disconnected` 自愈逻辑）：

```ts
import puppeteer, { Browser } from 'puppeteer';

const MAX_RENDERS = 200;            // 每 N 次渲染回收一次
const MAX_AGE_MS = 20 * 60 * 1000;  // 或每 T 分钟回收一次

let browser: Browser | null = null;
let launching: Promise<Browser> | null = null;
let recycling: Promise<void> | null = null;
let launchedAt = 0;
let renderCount = 0;
let inFlight = 0;
let idleWaiters: Array<() => void> = [];

function launch(): Promise<Browser> {
  launching ??= puppeteer
    .launch({ headless: true })
    .then((b) => {
      browser = b;
      launchedAt = Date.now();
      renderCount = 0;
      return b;
    })
    .finally(() => { launching = null; });
  return launching;
}

// 拿到浏览器的同时登记在途：检查和 inFlight++ 之间没有 await，回收插不进来
async function acquire(): Promise<Browser> {
  for (;;) {
    if (recycling) { await recycling; continue; }            // 闸门：等回收结束
    if (browser?.connected) { inFlight++; return browser; }
    await launch();
  }
}

function release(): void {
  inFlight--;
  renderCount++;
  if (inFlight === 0) idleWaiters.splice(0).forEach((wake) => wake());
}

function drained(): Promise<void> {
  return inFlight === 0
    ? Promise.resolve()
    : new Promise((wake) => idleWaiters.push(wake));
}

export async function renderPdf(html: string): Promise<Uint8Array> {
  const b = await acquire();
  try {
    const page = await b.newPage();
    try {
      await page.setContent(html, { waitUntil: 'networkidle0' });
      return await page.pdf({ format: 'A4', printBackground: true });
    } finally {
      await page.close();
    }
  } finally {
    release();
    maybeRecycle();                                          // PDF 已产出，再考虑回收
  }
}

function maybeRecycle(): void {
  if (recycling || !browser) return;
  const due =
    renderCount >= MAX_RENDERS || Date.now() - launchedAt >= MAX_AGE_MS;
  if (!due) return;

  const old = browser;
  recycling = drained()                                      // 闸门已关，等在途请求做完
    .then(() => {
      browser = null;
      return old.close();
    })
    .catch((err) => {
      console.warn('browser recycle failed', err);           // 不抛给调用方
      old.process()?.kill('SIGKILL');                        // 关不掉就直接杀，别留孤儿进程
    })
    .finally(() => { recycling = null; });
}
```

几点说明：

- **阈值放进配置中心**，调节奏不需要发版。目标是每 15–30 分钟回收一次：足够频繁，让锯齿保持平缓；又足够稀疏，让冷启动开销淹没在噪声里。
- **回收那一刻会有一个延迟尖峰**：闸门期间的新请求要等最慢的在途渲染做完，再加一次冷启动。按上面的节奏，它会在 p99 上表现为每 15–30 分钟一个小毛刺。如果这不可接受，可以改成"先拉起新浏览器接流量，旧浏览器排空后再关"，代价是切换期间两个 Chrome 同时在内存里，limit 要留出余量。
- **时间阈值只在请求结束时检查**。没有流量的时候不会触发回收，但这时候浏览器也不在分配新的共享内存，累积本来就停了。

这是**缓解，不是根治**。它把累积限制住了，而不是阻止它发生。但它今天就能上，不需要团队之外的任何人配合，而且它把一个以"重启 Pod"结尾的故事，变成了一个以"曲线看着像锯子"结尾的故事。

## 六、可观测性：让告警说实话

既然上涨的主要是可回收的内核 slab，告警就不应该直接拿 `container_memory_working_set_bytes` 去比阈值。working set 的算法是 cgroup 总用量减去不活跃的文件页，记在这个 cgroup 上的 slab 不管可不可回收都留在里面。HPA 如果按内存扩缩，读的也是这个数，于是一个无害的内核缓存还可能触发错误扩容。

可以有两种改法：

- **排除可回收 slab**：用 working set 减去本 cgroup `memory.stat` 里的 `slab_reclaimable`（节点视角对应的是 `/proc/meminfo` 的 `SReclaimable`，但那是整台机器的数，不能直接拿来减）。这需要采集链路能拿到 cgroup 级的 slab 字段，要和 SRE 确认现有 exporter 是否支持。
- **改用 RSS 类指标**：比如 cAdvisor 的 `container_memory_rss`，它更贴近进程真实占用，不包含内核为文件元数据记的 slab。

改用 RSS 时有一个坑要注意：**tmpfs 里的页不算在 RSS 里**。第一节把共享内存挪到 `/dev/shm` 之后，那部分是实打实会导致 OOM 的内存，RSS 却看不见它。所以如果告警换成 RSS，就要给 `/dev/shm` 单独加一项监控，比如在应用里定期上报 `statfs('/dev/shm')` 的已用量，并按 `sizeLimit` 设阈值。

一个比较稳妥的组合是：

| 告警 | 指标 | 回答的问题 |
| --- | --- | --- |
| 服务内存 | RSS（或 working set 减 `slab_reclaimable`） | 进程自己是不是在涨 |
| 共享内存 | `/dev/shm` 已用量 / `sizeLimit` | tmpfs 是不是快满了 |
| OOM 兜底 | working set 接近 limit（阈值放宽，比如 95%） | 是不是真的要被杀了 |

## 七、小结

| 层次 | 改动 | 解决什么 | 谁来做 |
| --- | --- | --- | --- |
| 应用 | 每 N 次渲染 / T 分钟回收 Chrome | 限制累积，斜坡变锯齿 | 应用团队，可立即落地 |
| 基础设施 | `/dev/shm` 用 `emptyDir{medium: Memory, sizeLimit: 1Gi}`，去掉 `--disable-dev-shm-usage` | 从源头上不再产生 XFS / overlay 元数据 | 需要基础设施 / SRE 配合 |
| 可观测性 | 告警排除可回收 slab，或改用 RSS 并单独监控 `/dev/shm` | 不再因为一个可回收的内核缓存而告警 | 需要基础设施 / SRE 配合 |

三者相互独立，可以叠加。应用层的修复让问题变得可以忍受；`/dev/shm` 的修复把机制本身拿掉；指标的修复让告警说实话。落地顺序上，应用层今天就能上；指标和 `/dev/shm` 可以并行推进，后者灰度时盯紧 renderer 崩溃率。

最后是那条值得带到下一个服务去的普遍教训：**一个你从网上某个 Dockerfile 抄来、用于止崩的 flag，有可能是一笔交易，而不是一个修复。** `--disable-dev-shm-usage` 是用"把本该在 RAM 里干的活挪到磁盘后备的文件系统上"换来的稳定性。正确答案从一开始就是：给容器它该有的那个 `/dev/shm`。

这条教训对做 agent 的同学同样适用：如果你的 agent 在容器里驱动无头浏览器做网页浏览、截图或导出，先检查一下 `/dev/shm` 的大小和启动参数，别让同一个坑再踩一遍。

## 附录：本篇新增术语

上篇附录里已经介绍过的内核、fd、inode、dentry、slab、tmpfs、overlayfs、cgroup 等概念，这里不再重复。

### emptyDir 与 medium: Memory

**emptyDir** 是 Kubernetes 的一种临时卷：Pod 启动时创建，Pod 删除时一起消失。默认它是节点磁盘上的一个目录；加上 `medium: Memory` 后，kubelet 会把它挂成 tmpfs，内容完全在内存里。

### sizeLimit 与 feature gate

**`sizeLimit`** 是 emptyDir 的容量上限。**feature gate** 是 Kubernetes 用来控制实验性功能开关的机制，新功能在正式稳定（GA）之前往往需要显式打开。memory-backed emptyDir 的尺寸限制曾经就由 `SizeMemoryBackedVolumes` 这个 feature gate 控制。

### memory limit 与 OOM kill

**memory limit** 是给容器设定的内存上限，由 cgroup 强制执行。容器用量超过上限、内核又回收不出足够内存时，会触发 **OOM kill**（Out Of Memory），直接杀掉容器里的进程。可回收的 slab 会先被回收，所以上篇的场景里轮不到 OOM kill；但 tmpfs 里的页不能随意丢弃，会实打实地占着 limit。

### page cache

**page cache** 是内核用来缓存文件内容的内存。读写磁盘文件时，数据先进入 page cache，之后再按需写回磁盘。tmpfs 的文件内容也放在这些页里，只不过没有"写回磁盘"这一步。

### 日志（journal）与 xfs_ili

日志文件系统（如 XFS、ext4）在修改元数据前，会先把"打算做什么"写进**日志**（journal），这样断电后可以恢复到一致状态。**`xfs_ili`** 就是 XFS 为 inode 记日志时用到的内核对象。对于共享内存这种用完即弃的临时文件，这份可靠性保障完全是多余的开销。

### memfd_create

**`memfd_create`** 是 Linux 提供的一个系统调用，可以直接创建一块"匿名文件"形式的内存：它有 fd，可以 `mmap` 和在进程间传递，但不出现在任何文件系统目录里，也就不会产生路径相关的 dentry 元数据。这是比"在目录里建文件再删名字"更干净的共享内存方式。

### seccomp 与沙箱

**seccomp** 是 Linux 限制进程能调用哪些系统调用的安全机制。Chrome 的沙箱和容器运行时都可能用它屏蔽部分系统调用；如果 `memfd_create` 被屏蔽，Chrome 就只能退回到基于文件的共享内存。

### HPA

**HPA**（Horizontal Pod Autoscaler）是 Kubernetes 的水平自动扩缩容，根据 CPU、内存等指标自动增减 Pod 数量。如果它读的内存指标里混着可回收 slab，就可能因为一个无害的内核缓存而错误扩容。

### RSS

**RSS**（Resident Set Size）是进程实际驻留在物理内存里的页数，比 cgroup 总用量更贴近"这个进程自己吃了多少内存"，不包含内核为文件元数据记的 slab。注意：容器监控里的 RSS 通常也不包含 tmpfs（`/dev/shm`）里的页。

### 冷启动

**冷启动**指浏览器进程从零启动到可以接收请求的这段时间。回收浏览器意味着每次回收都要付一次冷启动的开销，所以回收频率要在"内存累积"和"启动成本"之间取平衡。
