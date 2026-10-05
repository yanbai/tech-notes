# tech-notes

感想，经验和文字

Write-ups of real production problems: what happened, why it happened, and what I took away from it.

## Writings

| Topic | Article | Status |
| --- | --- | --- |
| How a headless Chrome Pod leaked 3GB of kernel memory | [Part 1: Diagnosis](./chrome-shmem-dentry-part1.md) | Published |
| | Part 2: The fix (`/dev/shm`, browser recycling, honest memory metrics) | In progress |

## Lessons Learned

- **"Memory going up" is not the same as "a process leaking memory".** The 3GB was in kernel slab caches (`dentry`, `xfs_inode`, `xfs_ili`), not in any process. Check `slabtop` and `/proc/meminfo` (`SReclaimable`) before reaching for a heap profiler.
- **`(deleted)` entries in `/proc/<pid>/fd` are a strong clue.** An unlinked file stays alive, along with its inode and dentry, for as long as any fd still points at it.
- **Every copy-pasted flag is a trade-off you inherit.** `--disable-dev-shm-usage` fixes Chrome crashing on Docker's 64MB `/dev/shm` by moving shared memory to a disk-backed, overlayfs `/tmp`. It trades a hard crash for a slow leak. Know what a flag costs before you ship it.
- **Containers share the node's kernel.** `/proc/slabinfo` is not namespaced, so what you see inside a Pod is the whole node's total. Keep that in mind before blaming your own service for all of it.
- **Container memory metrics include reclaimable kernel slab.** `container_memory_working_set_bytes` counts it, so a dashboard can climb and alerts can fire while the service is in no danger at all. Fixing the cause and fixing the metric are two separate jobs.
- **Be honest about how far the evidence goes.** I did not trace all 15.9 million dentries back to exact paths. What the evidence does support is the mechanism. Saying "confident" rather than "complete" is more useful than overclaiming.

## Reflections

This started as a routine ticket, "the PDF service needs a restart again", and turned into a tour of Linux internals I had used for years without really understanding: how `unlink()` works, why a deleted file still costs memory, and how a container's filesystem is stacked on top of the host's.

What stayed with me most is how reasonable each individual decision was. The flag came from every "Chrome in Docker" tutorial. The small `/dev/shm` was a sensible runtime default. The memory metric is the standard one. No single choice was wrong, but together they produced a service that looked broken while it was actually fine. Many production problems look like this: no single bug, just defaults that interact badly.

Writing it up was part of the debugging. Explaining each step in plain language, including a glossary for readers who don't work on kernels, showed me which parts I actually understood and which parts I was only pattern-matching. The fix only became clear once the explanation was.
