---
title: "k8s排障案例-runc init 卡住"
date: 2026-03-03T10:03:15+08:00
lastmod: 2026-03-03T10:03:15+08:00
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



近期工作中遇到一个k8s node节点无法创建容器的案例，本文分享其中的排障过程，总结涉及到的技术原理。

<!--more-->

## 现象与排障过程

业务上发现大量 pod 无法正常响应请求，查看这些pod 都是在同一个 node 节点，并且通过删除pod，重启时会卡在创建容器的过程中，错误信息显示为containerd无响应。查看此node 节点的资源使用情况，发现 system load average 高，但是 CPU 使用率很低。内存中缓存（cache+buffer）占用下降。

登录到 node 后台，执行`ps -eo pid,stat,wchan:30,comm | grep D`发现大量runc init 进程在等待`rwsem_down_write_slowpath`信号量，处于不可打断状态。还有kworker进程在等待`rq_qos_wait`。这也印证了为什么容器创建失败，因为重启创建容器时containerd会调用runc，runc在执行创建任务时会先执行runc init 初始化容器环境。`rwsem_down_write_slowpath`信号量表明runc init 在等待内核 IO 锁，此时已基本锁定是 IO 问题导致内核 IO 锁无法释放，导致大量runc init 进程进入等待 IO 的不可打断状态，kubelet 不断重试又导致更多 runc init 进程竞争 IO 锁，进入恶性循环。下一步就是找到 IO 问题的元凶。

首先查看各磁盘的性能情况：使用`iostat -sxz 1`发现sdb 磁盘使用率接近100%，await等待时间和aqu-sz等待队列都很大，dm-4设备映射同样使用率接近100%。其中dm-4设备是lvm（逻辑卷）的一个映射，`ls -l /dev/mapper/` 查看其lvm是kubelet_lv，`lsblk`可以显示pv-lv-mount的关系，可以看到dm-4背后的物理磁盘也是sdb，现在可以确认就是sdb被某个进程打满导致runc init 夯住，所有容器创建操作失败。

需要找到把sdb磁盘占满的元凶，容易想到的是找到挂载点，看看是什么文件在写。通过`findmnt {lv_name}`发现都是kubelet为容器创建的临时卷，因为本node上容器众多，无法准确定位是哪个pod在写。另一个思路是找出IO高的进程，使用`iotop -Po`，发现有部分java进程每秒写入达几十MB。初步怀疑就是这几个进程把sdb磁盘io占满，导致runc init 的io操作无法完成。因为这个node上有大量不同团队的pod，现在的问题是这个进程是属于哪个pod的。

从pid找对应的容器和pod的方法有很多，这里介绍一个最通用方法，先`cat /proc/{pid}/cgroup` ，看到类似`0::/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod[UID].slice/cri-containerd-[ID].scope`的内容，`crictl ps -a |grep {containerID}` 可以直接看到pod name。

真凶就是这些pod，为了反向验证猜想，把这些高io 的pod从本node驱离，发现容器创建恢复正常了。

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
