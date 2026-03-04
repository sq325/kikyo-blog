---
title: "k8s排障案例-runc init 卡住导致容器创建失败"
date: 2026-03-03T10:03:15+08:00
lastmod: 2026-03-04T10:03:15+08:00
draft: true
keywords: []
description: ""
tags: ["k8s", "linux"]
categories: ["技术"]
author: ""

# You can also close(false) or open(true) something for this content.
# P.S. comment can only be closed
comment: true
toc: true
autoCollapseToc: false
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
  enable: true
  options: ""

sequenceDiagrams: 
  enable: true
  options: ""

---

近期工作中遇到一个 K8s Node 节点无法创建容器的典型案例，本文分享其中的排障过程，并总结涉及到的技术原理。
<!--more-->

## 现象描述

业务侧反馈大量 Pod 无法正常响应请求。通过观察发现，受影响的 Pod 均集中在同一个 Node 节点。

**初步观察：**

1. **Pod 状态：** 删除 Pod 后，新生成的 Pod 长期卡在 `ContainerCreating` 阶段。
2. **错误详情：** `kubectl describe pod` 显示错误信息为 `context deadline exceeded`，提示 Containerd 响应超时。
3. **资源监控：** 该 Node 节点 **System Load Average 非常高**，但 CPU 使用率却很低，内存中的 Cache/Buffer 占用出现明显下降。

## 排障过程：层层剥茧

### 1. 寻找阻塞源

登录 Node 后台，通过 `ps` 命令查看 D 状态（不可中断睡眠）进程：

```bash
ps -eo pid,stat,wchan:30,comm | grep D
```

发现大量 `runc init` 进程在等待 `rwsem_down_write_slowpath` 信号量。`rwsem` 是读写信号量，这表明进程正卡在内核级别的读写锁竞争上。此外，还有 `kworker` 进程在等待 `rq_qos_wait`（通常与块设备 IO 节流相关）。

**结论：** 容器创建失败是因为 Containerd 调用 `runc` 时，`runc init` 在准备容器环境（如挂载文件系统）时卡在了内核 IO 锁上。由于 Kubelet 不断重试，导致更多进程竞争锁，陷入恶性循环。

### 2. 定位 IO 异常设备

使用 `iostat` 工具观察磁盘实时性能：

```bash
iostat -sxz 1
```

**发现异常：**

- `sdb` 磁盘的使用率（`%util`）接近 100%。
- `w_await`（写入等待时间）和 `aqu-sz`（等待队列长度）均远超正常范围。
- `dm-4` 设备映射同样满负载。

通过 `lsblk` 和 `ls -l /dev/mapper/` 确认，`dm-4` 对应的是 `kubelet_lv`。这意味着 **Kubelet 管理的相关目录所在的物理磁盘 IO 已经打满。**

### 3. 揪出 IO “元凶”

虽然已知 `sdb` 磁盘 IO 很高，但 Kubelet 目录下存在大量容器的临时卷。使用 `iotop` 监控进程级别的 IO：

```bash
iotop -Po
```

**定位：** 发现几个 Java 进程正在以几十 MB/s 的速度高频写入。

### 4. 关联进程与 Pod

为了确认这些 Java 进程属于哪个 Pod，采用以下通用方法：

1. **获取容器 ID：** 查看进程的 cgroup 信息：

   ```bash
   cat /proc/{PID}/cgroup
   ```

   从中解析出类似 `0::/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod[UID].slice/cri-containerd-[ID].scope`的内容，`crictl ps -a |grep {containerID}` 中的 ID。

2. **定位 Pod：** 使用 `crictl` 查询：

   ```bash
   crictl ps -a | grep {CONTAINER_ID}
   ```

确认真凶是某业务 Pod 后，将其驱逐出该节点。随着高 IO 压力的消失，该节点的容器创建功能立刻恢复正常。

## 排查思路整理

k8s event初步定位：

- `kubectl describe` 查看 event
- kubelet打印的内容是context deadline exceeded，一般是这个node的kubelet或者下游组件有问题，需要登录到node节点查看。（需要对容器创建流程有了解）

node 上 linux命令排查：

- `uptime` 查看 load average，查看 CPU、内存使用情况。

- 查找 D 状态进程：`ps -eo pid,stat,wchan:30,comm | grep -E 'D|runc'`
- 确认磁盘 IO 情况：`iostat -sxz 1`
  - `w_await`：一般超过100ms说明磁盘可用性已经受到影响。
  - `aqu-sz`：大于1说明IO堆积。
  - `%util`：接近 100% 说明磁盘满负荷
- 确认磁盘和逻辑卷的映射关系：`lsblk`、`ls -l /dev/mapper`
- 确认进程IO情况：`iotop -Po`
- 从pid定位具体pod：
  - 取出containerID：`cat /proc/{pid}/cgroup`
  - 查找pod name: `crictl ps -a |grep {containerID}`

## 涉及原理知识

### 进程 D 状态是什么？

linux 进程有两种睡眠状态，S（Interruptible Sleep）和D（Uninterruptible Sleep）。其中S状态的进程正在等待某个事件（如键盘输入）再执行后续操作，此时会被内核挂起，不占用CPU资源，属于正常工作流程中的一环，只要事件到来，进程会被唤起并执行后续工作。

D状态的进程在等待IO操作或者在获取内核中的某个锁，因为这些资源往往是内核级别的公用资源（如文件系统、命名空间）或者是等待某个硬件返回数据（硬盘），为了保证一致性不被破坏，不响应任何信号（kill -9 也不起作用）

通过`cat /proc/{pid}/stack`可以查看进程调用栈，确定D状态进程卡在哪个系统调用上。

### kworker是什么进程？

kworker是Linux内核工作线程，当业务进程调用`write()`向某个文件写入数据时，为了优化性能，内核并不等待磁盘IO完成再返回，而是立刻返回，数据先被写入内存 Page Cache，等积累到一定量或超过一定时间后，再由kworker进程一并刷入硬盘。`kworker` 还负责将脏页（dirty page）中的文件系统元数据（如 Inode）和日志写回磁盘。

### runc init 做哪些操作，为什么要等待内核锁？

`runc init` 负责为容器准备初始环境，因为容器本质上是一组受控的进程，runc init 负责准备"受控"环境，具体包括：配置各种 namespace、挂载各种 volume、写入进程对应的 cgroup 文件。

### 磁盘隔离contianerd和kubelet的volume能否避免此问题？

containerd 默认路径 `/var/lib/containerd/` 主要功能是把静态的image转换成动态可读写的容器rootfs。

kubelet 默认路径 `/var/lib/kubelet/` 主要功能是把 pod yaml中定义各种volume（empydir、configmap等）挂载进容器的命名空间。

runc 启动一个容器，会先挂载containerd 准备好的 rootfs。再根据yaml 的定义把各种 volume挂载到这个rootfs上。本文中`/var/lib/containerd/`和`/var/lib/kubelet/`虽然不是一个lvm，但是底层同属于一个磁盘，当pod 通过emptydir 对`/var/lib/kubelet/` 执行大量io操作，会同时影响到`/var/lib/containerd/`的操作。

如果磁盘隔离这两个lvm，runc 第一步挂载rootfs不受影响，但是 runc 还需要在 `/var/lib/kubelet/pods/<pod-id>/volumes/...`下挂载yaml中定义的各种volume，会卡在这一步。

一个有效的方法是把pod流量和runc 对 rootfs的操作隔离在不同的磁盘，这需要pod把io的流量达到pv上而不是emptydir。


## 总结

**核心原因：**当某个 Pod 高频写入 `/var/lib/kubelet/pods/...` 时，会引发该块设备的 IO 队列深度极高，甚至触发内核的文件系统日志（如 ext4 jbd2）或 VFS 级别读写信号量（`rwsem`）的阻塞。因此新的 `runc init` 试图做 mount 操作时，不可避免地陷入 D 状态。

**底层原因：**由于emptydir在kubelet的lvm下，pod对emptydir的高io操作会影响到runc对容器环境初始化。

**排查难点：**

1. 确认根因是 IO 导致容器初始化失败。
2. 定位高 IO 硬盘。
3. 定位高 IO 应用。

**改进：**
1. IO 限制：对于 IO 密集型应用，应避免使用 `emptyDir` 进行高频大流量读写，建议使用带 IO 限速（IOPS/Throughput Quota）的外部卷或本地持久化卷。
2. 磁盘分离：如果条件允许，将容器运行时（RootFS）所在的磁盘与应用数据卷（Kubelet Pod 目录）所在的物理磁盘分离。

