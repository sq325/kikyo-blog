---
title: "容器内存指标用哪个"
date: 2024-05-02T22:29:41+08:00
lastmod: 2024-05-02T22:29:41+08:00
draft: false
keywords: []
description: ""
tags: ["Prometheus", "k8s"]
categories: ["技术"]
author: ""

# You can also close(false) or open(true) something for this content.
# P.S. comment can only be closed
comment: true
toc: true
autoCollapseToc: true
postMetaInFooter: true
hiddenFromHomePage: false
# You can also define another contentCopyright. e.g. contentCopyright: "This is another copyright."
contentCopyright: false
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false

# You can enable or disable out-of-date content warning for individual post.
# Comment this out to use the global config.
#enableOutdatedInfoWarning: false

flowchartDiagrams:
  enable: false
  options: ""

sequenceDiagrams: 
  enable: false
  options: ""

---

<!--more-->

# 容器内存指标来源

容器本质上是 linux 进程，与普通进程不同的是，容器的资源使用受 cgroup 管理，cgroup 是 linux 内核提供的一种资源隔离机制，可以限制进程的资源使用。通过 Prometheus 收集的容器内存指标由 cadvisor 采集，cadvisor 是一个开源的容器监控工具，由 google 开发，用于监控容器的资源使用情况。cadvisor 通过读取 cgroup 的内存统计信息，计算出容器的内存使用情况。
cgroup 内存信息记录在 `/sys/fs/cgroup/memory.XXX` 文件下，cadvisor 通过读取这些文件获取容器的内存使用情况。
其中cgroup v1 和 v2 的内存指标文件不同，如下源码所示：

```go
// cgroup v1
moduleName := "memory"
var (
  usage    = moduleName + ".usage_in_bytes"
  maxUsage = moduleName + ".max_usage_in_bytes"
  failcnt  = moduleName + ".failcnt"
  limit    = moduleName + ".limit_in_bytes"
)

// cgroup v2
usage := moduleName + ".current"
limit := moduleName + ".max"
maxUsage := moduleName + ".peak"
```

下面以cgroup v2 为例，介绍容器内存指标的计算。
获取内存的主要逻辑实现在 github.com/opencontainers/runc/libcontainer/cgroups/fs2/memory.go 的 statMemory 函数中。该函数通过直接读取 cgroup 文件，获取 memory.stat、usage、swap、cache 内存信息。：

```go
// github.com/opencontainers/runc/libcontainer/cgroups/fs2/memory.go
// statMemory 函数通过读取 cgroup 文件获取各种内存信息
func statMemory(dirPath string, stats *cgroups.Stats) error {
	const file = "memory.stat"
	statsFile, err := cgroups.OpenFile(dirPath, file, os.O_RDONLY)
	...
	defer statsFile.Close()

	sc := bufio.NewScanner(statsFile)
	for sc.Scan() {
		t, v, err := fscommon.ParseKeyValue(sc.Text())
		...
		stats.MemoryStats.Stats[t] = v
	}
	...
  // cache
	stats.MemoryStats.Cache = stats.MemoryStats.Stats["file"]
	stats.MemoryStats.UseHierarchy = true

  // usage
  // 来自 /sys/fs/cgroup/memory.current
	memoryUsage, err := getMemoryDataV2(dirPath, "")
	...
	stats.MemoryStats.Usage = memoryUsage
  
  // swap
	swapOnlyUsage, err := getMemoryDataV2(dirPath, "swap")
	if err != nil {
		return err
	}
	stats.MemoryStats.SwapOnlyUsage = swapOnlyUsage
	swapUsage := swapOnlyUsage
	swapUsage.Usage += memoryUsage.Usage
	if swapUsage.Limit != math.MaxUint64 {
		swapUsage.Limit += memoryUsage.Limit
	}

	swapUsage.MaxUsage = 0
	stats.MemoryStats.SwapUsage = swapUsage

	return nil
}
```

接下来详细解析 cadvisor 是如何计算出各种容器内存指标的。

# cadvisor 内存指标

cadvisor 提供了以下内存指标：

- `container_memory_working_set_bytes`
- `container_memory_usage_bytes`
- `container_memory_rss`
- `container_memory_cache`
- `container_memory_kernel_usage`
- `container_memory_mapped_file`
- `container_memory_swap`
- `container_memory_max_usage_bytes`

## container_memory_usage_bytes

`container_memory_usage_bytes` 指标值取自 `/sys/fs/cgroup/memory.current` 文件，源码如下

```go
// github.com/opencontainers/runc/libcontainer/cgroups/fs2/memory.go
memoryUsage, err := getMemoryDataV2(dirPath, "")

func getMemoryDataV2(path, name string) (cgroups.MemoryData, error) {
	...
	moduleName := "memory"
	...
	usage := moduleName + ".current"
	limit := moduleName + ".max"
	maxUsage := moduleName + ".peak"

	value, err := fscommon.GetCgroupParamUint(path, usage)
  ... 
	memoryData.Usage = value
	...
}
```

上述代码表明，`container_memory_usage_bytes` 指标从 `memory.current` 文件读取当前容器的内存使用量，这包括了容器的总内存使用量，即容器进程的内存使用加上内核为容器分配的缓存（如文件系统缓存）。这意味着该指标反映的是该 cgroup 下所有被访问的内存页的总量。
通常不会以 `container_memory_usage_bytes` 作为监控指标，因为它包含了文件缓存，且k8s的内存资源分配是基于 `container_memory_working_set_bytes`，`container_memory_usage_bytes >= container_memory_working_set_bytes`。
计算公式如：`container_memory_usage_bytes = container_memory_rss + container_memory_cache + kernel memory`

## container_memory_swap

`container_memory_swap` 表示容器的交换内存使用量，取自 memory.swap.current 文件。

```bash
/sys/fs/cgroup # cat memory.swap.current
0
```

## container_memory_working_set_bytes

`container_memory_working_set_bytes` 是最常使用的内存指标，用于监控容器的内存使用情况，因为 `container_memory_working_set_bytes` 只包含活跃的内存使用，更能反映容器的实际内存使用情况。
`container_memory_working_set_bytes` 的计算公式为：`container_memory_working_set_bytes = container_memory_usage_bytes - total_inactive_file`
源码如下：

```go
workingSet := ret.Memory.Usage 
if v, ok := s.MemoryStats.Stats[inactiveFileKeyName]; ok {
  if workingSet < v {
   workingSet = 0
  } else {
   workingSet -= v
  }
}
ret.Memory.WorkingSet = workingSet
```

其中 `total_inactive_file` 是容器的文件缓存大小，取自 memory.stat 文件中的 inactive_file 值。

```bash
/sys/fs/cgroup # cat memory.stat |grep -i inactive_file
inactive_file 4096
```

## container_memory_cache & container_memory_rss

cache 和 rss 的计算逻辑如下：

```go
ret.Memory.Usage = s.MemoryStats.Usage.Usage
ret.Memory.MaxUsage = s.MemoryStats.Usage.MaxUsage
ret.Memory.Failcnt = s.MemoryStats.Usage.Failcnt
ret.Memory.KernelUsage = s.MemoryStats.KernelUsage.Usage

// cache rss swap mapped_file
if cgroups.IsCgroup2UnifiedMode() {
	ret.Memory.Cache = s.MemoryStats.Stats["file"]
	ret.Memory.RSS = s.MemoryStats.Stats["anon"]
	ret.Memory.Swap = s.MemoryStats.SwapUsage.Usage - s.MemoryStats.Usage.Usage
	ret.Memory.MappedFile = s.MemoryStats.Stats["file_mapped"]
} else if s.MemoryStats.UseHierarchy {
	ret.Memory.Cache = s.MemoryStats.Stats["total_cache"]
	ret.Memory.RSS = s.MemoryStats.Stats["total_rss"]
	ret.Memory.Swap = s.MemoryStats.Stats["total_swap"]
	ret.Memory.MappedFile = s.MemoryStats.Stats["total_mapped_file"]
} else {
	ret.Memory.Cache = s.MemoryStats.Stats["cache"]
	ret.Memory.RSS = s.MemoryStats.Stats["rss"]
	ret.Memory.Swap = s.MemoryStats.Stats["swap"]
	ret.Memory.MappedFile = s.MemoryStats.Stats["mapped_file"]
}

// page faults
if v, ok := s.MemoryStats.Stats["pgfault"]; ok {
	ret.Memory.ContainerData.Pgfault = v
	ret.Memory.HierarchicalData.Pgfault = v
}
if v, ok := s.MemoryStats.Stats["pgmajfault"]; ok {
	ret.Memory.ContainerData.Pgmajfault = v
	ret.Memory.HierarchicalData.Pgmajfault = v
}

```

其中 `container_memory_cache` 和 `container_memory_rss` 分别来自 memory.stat 文件中的 file 和 anon 的值。

```bash
# cache
/sys/fs/cgroup # cat memory.stat |grep -i file
file 24576

# rss
/sys/fs/cgroup # cat memory.stat |grep -i anon
anon 561152
```

## container_memory_working_set_bytes or container_memory_rss？

有时候使用 `container_memory_rss` 可能比 `container_memory_working_set_bytes` 更合适，因为 `container_memory_rss` 只包含容器的常驻内存，不包含文件缓存。本人就遇到过部分容器的 `container_memory_working_set_bytes` 指标已经很高，但是 `container_memory_rss` 指标很低，发现是日志文件缓存占用了大量内存，但是文件缓存在内存不足时会被释放，`container_memory_working_set_bytes` 指标也会随之下降，对程序本身的使用没有影响，所以本人认为在这种情况下 `container_memory_working_set_bytes` 并不能真正反映内存压力，因为还有很多可以释放的内存可供容器使用。
而 `container_memory_rss` 表示容器所有运行中的代码和数据段所占用的内存，这包括容器正在使用的实际物理内存，不包括文件缓存、交换分区或未使用的内存等，是与文件缓存无关的内存使用情况。当 `container_memory_rss` 高时，表示程序本身占用的内存多，这些内存都是不可释放的。
**至于为什么k8s使用 `container_memory_working_set_bytes` 作为pod调度时资源使用的依据，而不是 `container_memory_rss` ？**在[k8s官方文档](https://kubernetes.io/zh-cn/docs/concepts/scheduling-eviction/node-pressure-eviction/#active-file-内存未被视为可用内存)中有这样一段说明：

> kubelet 将 active_file 内存区域视为不可回收。 对于大量使用块设备形式的本地存储（包括临时本地存储）的工作负载， 文件和块数据的内核级缓存意味着许多最近访问的缓存页面可能被计为 active_file。 如果这些内核块缓冲区中在活动 LRU 列表上有足够多， kubelet 很容易将其视为资源用量过量并为节点设置内存压力污点，从而触发 Pod 驱逐。你可以通过为可能执行 I/O 密集型活动的容器设置相同的内存限制和内存请求来应对该行为。

这一点在 [kubernetes github issue](https://github.com/kubernetes/kubernetes/issues/43916) 中有详细讨论，官方至今并没有更改。

# 参考

[kubelet counts active page cache against memory.available](https://github.com/kubernetes/kubernetes/issues/43916)

[active_file 内存未被视为可用内存](https://kubernetes.io/zh-cn/docs/concepts/scheduling-eviction/node-pressure-eviction/#active-file-内存未被视为可用内存)

[K8S内存消耗，到底该看哪个图？](https://cloud.tencent.com/developer/article/2070537)

[记一次go应用在k8s pod已用内存告警不准确分析](https://www.cnblogs.com/mikevictor07/p/17968696)

[Cadvisor内存使用率指标](https://www.orchome.com/6745)
