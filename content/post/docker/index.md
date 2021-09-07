---
title: "docker"
date: 2021-09-07T12:06:51+08:00
lastmod: 2021-09-07T12:06:51+08:00
draft: true
keywords: []
description: ""
tags: ["docker"]
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


Category: 虚拟化/编排
Created: August 13, 2021 11:41 PM

[Docker run reference](https://docs.docker.com/engine/reference/run/)

官方文档

[Docker - 从入门到实践](https://vuepress.mirror.docker-practice.com/)

[前言](https://yeasy.gitbook.io/docker_practice/)

[联合文件系统](https://books.studygolang.com/docker_practice/underly/ufs.html)

[10张图带你深入理解Docker容器和镜像](http://dockone.io/article/783)

[掘金](https://juejin.cn/book/6844733746462064654)

[Play with Docker](https://labs.play-with-docker.com/)

# 概述

## 虚拟化

[虚拟化](https://www.notion.so/2dd60524d23b45d28765dd119565c30e) 

## Docker engine

> 由Clinet、Daemon、containerd和runc组成

![FF4FF9F5-A816-4F44-8D7C-BED315A846FC.jpeg](Docker%20dee6811f21094ba497f02633b55055ff/FF4FF9F5-A816-4F44-8D7C-BED315A846FC.jpeg)

![0DE7AB1C-689C-47BA-9541-FD42192FE87D.jpeg](Docker%20dee6811f21094ba497f02633b55055ff/0DE7AB1C-689C-47BA-9541-FD42192FE87D.jpeg)

### Docker daemon

daemon 使用一种 CRUD 风格的 API ，通过 gRPC 与 containerd 进行通信。虽然名叫 containerd ，但是它并不负责创建容器，而是指挥 runc 去做。 containerd 将 Docker 镜像转换为 OCI bundle ，并让 runc 基于此创建一个新的容器。然后， runc 与操作系统内核接口进行通信，基于所有必要的工具（ Namespace 、 CGroup 等）来创建容器。容器进程作为 runc 的子进程启动，启动完毕后， runc 将会退出。

daemon 的主要功能包括镜像管理、镜像构建、 REST API 、身份验证、安全、核心网络以及编排。

如果你在一台非 Linux 操作系统中使用 Docker ，客户端就运行在你的宿主操作系统上，但是守护进程运行在一个虚拟机内。由于构建目录中的文件都被上传到了守护进程中。

### contained

containerd 指挥 runc 来创建新容器。事实上，每次创建容器时它都会 fork 一个新的 runc 实例。不过，一旦容器创建完毕，对应的 runc 进程就会退出。因此，即使运行上百个容器，也无须保持上百个运行中的 runc 实例。一旦容器进程的父进程 runc 退出，相关联的 containerd-shim 进程就会成为容器的父进程。作为容器的父进程， shim 的部分职责如下。保持所有 STDIN 和 STDOUT 流是开启状态，从而当 daemon 重启的时候，容器不会因为管道（ pipe ）的关闭而终止。将容器的退出状态反馈给 daemon 。

### runc

> 容器运行时

runc 实质上是一个轻量级的、针对 Libcontainer 进行了包装的命令行交互工具

## 命名空间

> Namespaces，以隔离进程、网络、文件系统等虚拟资源为目的，分为PID、NET、MOUNT、IPC、UTS和USER Namespace

利用 PID Namespace，Docker 就实现了容器中隔离程序运行中进程隔离这一目标。

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled.png)

## 控制组

> control groups，硬件资源的隔离和分配

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%201.png)

## 联合文件系统

> Union File System

联合文件系统（UnionFS）是一种分层、轻量级并且高性能的文件系统，它支持对文件系统的修改作为一次提交来一层层的叠加，同时可以将不同目录（文件系统）挂载到同一个虚拟文件系统下(unite several directories into a single virtual filesystem)。

联合文件系统是 Docker 镜像的基础。镜像可以通过分层来进行继承，基于基础镜像（没有父镜像），可以制作各种具体的应用镜像。不同 Docker 容器就可以共享一些基础的文件系统层，同时再加上自己独有的改动层，大大提高了存储的效率。

## 存储驱动

每个 Docker 容器都有一个本地存储空间，用于保存层叠的镜像层（ Image Layer ）以及挂载的容器文件系统。默认情况下，容器的所有读写操作都发生在其镜像层上或挂载的文件系统中

linux：/etc/docker/daemon.json

linux上可用的

- AUFS
- Overlay2
- Device Mapper
- Btrfs
- ZFS

每种存储引擎都给予Linux中对应的文件系统或块技术

windows上可用的存储引擎：windowsfilter，基于NTFS上实现的。

## docker架构

c/s模式：docker为客户端，dockerd为服务端，2375端口，对外提供RESTFUL API

# 镜像

> 镜像（Image）就是一堆只读层（read-only layer）的统一视角，统一文件系统（union file system）技术能够将不同的层整合成一个文件系统，为这些层提供了一个统一的视角，这样就隐藏了多层的存在，在用户的角度看来，只存在一个文件系统。

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%202.png)

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%203.png)

元数据（metadata）就是关于这个层的额外信息，它不仅能够让Docker获取运行和构建时的信息，还包括父层的层次信息。需要注意，只读层和读写层都包含元数据。

除此之外，每一层都包括了一个指向父层的指针。如果一个层没有这个指针，说明它处于最底层。

镜像内部是一个精简的操作系统（ OS ），同时还包含应用运行所必须的文件和依赖包。

一旦容器从镜像启动后，二者之间就变成了互相依赖的关系，并且在镜像上启动的容器全部停止之前，镜像是无法被删除的。

每次对镜像内容的修改，Docker 都会将这些修改铸造成一个镜像层，而一个镜像其实就是由其下层所有的镜像层所组成的。当然，每一个镜像层单独拿出来，与它之下的镜像层都可以组成一个镜像。

另外，由于这种结构，Docker 的镜像实质上是无法被修改的，因为所有对镜像的修改只会产生新的镜像，而不是更新原有的镜像。

对于每一个记录文件系统修改的镜像层来说，Docker 都会根据它们的信息生成了一个 Hash 码

由于镜像层都有唯一的编码，我们就能够区分不同的镜像层并能保证它们的内容与编码是一致的，这带来了另一项好处，就是允许我们在镜像之间共享镜像层。

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%204.png)

**悬虚镜像**：没有标签的镜像。

## 镜像命名规则

镜像的命名我们可以分成三个部分：**username**、**repository** 和 **tag**。

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%205.png)

## 镜像摘要

> image digest，镜像的唯一标识，为镜像内容的散列值

```powershell
docker image ls --digests
docker image pull alpine@sha256:c0537....7c
```

## 构建

当构建的时候，用户会指定构建镜像上下文的路径，docker build 命令得知这个路径后，会将路径下的所有内容打包，然后上传给 Docker 引擎。这样 Docker 引擎收到这个上下文包后，展开就会获得构建镜像所需的一切文件。现在就可以理解刚才的命令 docker build -t nginx:v3 . 中的这个 .，实际上是在指定上下文的目录，docker build 命令会将该目录下的内容打包交给 Docker 引擎以帮助构建镜像。

`COPY ./package.json /app/`

这并不是要复制执行 docker build 命令所在的目录下的 package.json，也不是复制 Dockerfile 所在目录下的 package.json，而是复制 上下文（context） 目录下的 package.json。

一般来说，应该会将 Dockerfile 置于一个空目录下，或者项目根目录下。如果该目录下没有所需文件，那么应该把所需文件复制一份过来。如果目录下有些东西确实不希望构建时传给 Docker 引擎，那么可以用 .gitignore 一样的语法写一个 .dockerignore，该文件是用于剔除不需要作为上下文传递给 Docker 引擎的。

### Dockerfile

> Dockerfile 是 Docker 中用于定义镜像自动化构建流程的配置文件

[Dockerfile](Docker%20dee6811f21094ba497f02633b55055ff/Dockerfile%2065e4531c66a146a1a3ed30c0e23aed8b.md) 

在实际使用中，我们也很少会选择容器提交这种方法来构建镜像，而是几乎都采用 Dockerfile 来制作镜像。

`docker build -t webapp:latest -f ./webapp/a.Dockerfile ./webapp`

### 多阶段构建

# 容器

> 容器（container）的定义和镜像（image）几乎一模一样，也是一堆层的统一视角，唯一区别在于容器的最上面那一层是可读可写的。容器 = 镜像 + 读写层
一个容器只运行一个app
运行中的容器共享宿主机的内核，意味着一个基于Windows的容器在Linux上无法运行。

一个运行态容器（running container）被定义为一个可读写的统一文件系统加上隔离的进程空间和包含其中的进程。

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%206.png)

如果把镜像理解为编程中的类，那么容器就可以理解为类的实例

Docker 的容器应该有三项内容组成：

- 一个 Docker 镜像
- 一个程序运行环境
- 一个指令集合

## 生命周期

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%207.png)

- **Created**：容器已经被创建，容器所需的相关资源已经准备就绪，但容器中的程序还未处于运行状态。
- **Running**：容器正在运行，也就是容器中的应用正在运行。
- **Paused**：容器已暂停，表示容器中的所有程序都处于暂停 ( 不是停止 ) 状态，cpu空闲，内存占用。
- **Stopped**：容器处于停止状态，占用的资源和沙盒环境都依然存在，只是容器中的应用程序均已停止。
- **Deleted**：容器已删除，相关占用的资源及存储在 Docker 中的管理信息也都已释放和移除。

容器中运行的应用退出后，容器本身会进入stopped状态。

stop或者pause不会导致容器内部的数据丢失。

# 网络

## CNM

> 容器网络模型，libnetwork是CNM的实现。

![9748EFD4-D63F-4461-8D3E-AA0CA68E2A48.png](Docker%20dee6811f21094ba497f02633b55055ff/9748EFD4-D63F-4461-8D3E-AA0CA68E2A48.png)

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%208.png)

- **沙盒**提供了容器的虚拟网络栈，也就是之前所提到的端口套接字、IP 路由表、防火墙等的内容。其实现隔离了容器网络与宿主机网络，形成了完全独立的容器网络环境。
- **网络**可以理解为 Docker 内部的虚拟子网，网络内的参与者相互可见并能够进行通讯。Docker 的这种虚拟网络也是于宿主机网络存在隔离关系的，其目的主要是形成容器间的安全通讯环境。
- **端点**是位于容器或网络隔离墙之上的洞，其主要目的是形成一个可以控制的突破封闭的网络环境的出入口。当容器的端点与网络的端点形成配对后，就如同在这两者之间搭建了桥梁，便能够进行数据传输了。

## 网络驱动

### bridge

> 当 Docker 启动时，会自动在主机上创建一个 docker0 虚拟网桥，实际上是 Linux 的一个 bridge，可以理解为一个软件交换机。它会在挂载到它的网口之间进行转发。它在内核层连通了其他的物理或虚拟网卡，这就将所有容器和本地主机都放到同一个物理网络。每次创建一个新容器的时候，Docker 从可用的地址段中选择一个空闲的 IP 地址分配给容器的 eth0 端口。使用本地主机上 docker0 接口的 IP 作为所有容器的默认网关。

```bash
sudo brctl show
bridge name     bridge id               STP enabled     interfaces
docker0         8000.3a1d7362b4ee       no              veth65f9
                                             vethdda6
```

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%209.png)

### hostonly

### none

### overlay

### macvlan

## 容器间

> 把容器加入到同一个网络中（网桥）
建立容器间子网+容器端口暴露

### 容器→网桥→容器

- 容器的网络拓扑是否已经互联。默认情况下，所有容器都会被连接到 `docker0` 网桥上。
- 本地系统的防火墙软件 -- `iptables` 是否允许通过。

```bash
# 将box1和box2加入同一个网络
docker network create -d bridge my-net
docker run -it --name box1 --network my-net box:1.0 sh
docker run -it --name box2 --network my-net box:1.0 sh

# 在box1中ping box2 通
ping box2 
```

### 容器→容器

```bash
# 创建两个container
$ docker run -i -t --rm --net=none base /bin/bash
$ docker run -i -t --rm --net=none base /bin/bash

# 找到进程号
$ docker inspect -f '{{.State.Pid}}' 1f1f4c1f931a
2989
$ docker inspect -f '{{.State.Pid}}' 12e343489d2f
3004

# 创建网络命名空间的跟踪文件
$ sudo mkdir -p /var/run/netns
$ sudo ln -s /proc/2989/ns/net /var/run/netns/2989
$ sudo ln -s /proc/3004/ns/net /var/run/netns/3004

#创建一对 peer 接口，然后配置路由
$ sudo ip link add A type veth peer name B

$ sudo ip link set A netns 2989
$ sudo ip netns exec 2989 ip addr add 10.1.1.1/32 dev A
$ sudo ip netns exec 2989 ip link set A up
$ sudo ip netns exec 2989 ip route add 10.1.1.2/32 dev A

$ sudo ip link set B netns 3004
$ sudo ip netns exec 3004 ip addr add 10.1.1.2/32 dev B
$ sudo ip netns exec 3004 ip link set B up
$ sudo ip netns exec 3004 ip route add 10.1.1.1/32 dev B
```

## 容器与外部

> 端口映射+容器端口暴露

容器要想访问外部网络，需要本地系统的转发支持。在Linux 系统中，检查转发是否打开。

```bash
$sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 1
$sysctl -w net.ipv4.ip_forward=1
```

```bash
docker run -d -p 5000:80 nginx
```

### 容器→外部网络

> 容器所有到外部网络的连接，源地址都会被 NAT 成本地系统的 IP 地址。这是使用 iptables 的源地址伪装操作实现的。

host NAT配置：

```bash
$ sudo iptables -t nat -nL
...
Chain POSTROUTING (policy ACCEPT)
target     prot opt source               destination
MASQUERADE  all  --  172.17.0.0/16       !172.17.0.0/16
...
# 将所有源地址在 172.17.0.0/16 网段，目标地址为其他网段（外部网络）的流量动态伪装为从系统网卡发出。
```

### 外部网络→容器

> run时-p实现
原理为本地的 iptable 的 nat 表中添加相应的规则

```bash
# -p 80:80后
$ iptables -t nat -nL
Chain DOCKER (2 references)
target     prot opt source               destination
DNAT       tcp  --  0.0.0.0/0            0.0.0.0/0            tcp dpt:80 to:172.17.0.2:80
```

- 这里的规则映射了 `0.0.0.0`，意味着将接受主机来自所有接口的流量。用户可以通过 `p IP:host_port:container_port` 或 `p IP::port` 来指定允许访问容器的主机上的 IP、接口等，以制定更严格的规则。
- 如果希望永久绑定到某个固定的 IP 地址，可以在 Docker 配置文件 `/etc/docker/daemon.json` 中添加如下内容。

## DNS

> 默认用主机上的 /etc/resolv.conf 来配置容器。

host和container之间通过mount保持DNS同步

```bash
# 容器中使用
mount
/dev/disk/by-uuid/1fec...ebdf on /etc/hostname type ext4 ...
/dev/disk/by-uuid/1fec...ebdf on /etc/hosts type ext4 ...
tmpfs on /etc/resolv.conf type tmpfs ...
```

/etc/docker/daemon.json中配置

```json
{
  "dns" : [
    "114.114.114.114",
    "8.8.8.8"
  ]
}
```

run时手动添加

```bash
--hostname=HOSTNAME #会写到container中的/etc/hostname和/etc/hosts
--dns=IP_ADDRESS #会在/etc/resolv.conf
--dns-search=DOMAIN #设定容器的搜索域，当设定搜索域为 .example.com 时，在搜索一个名为 host 的主机时，DNS 不仅搜索 host，还会搜索 host.example.com。

```

## 多机覆盖网络

# 数据持久化

![Untitled](Docker%20dee6811f21094ba497f02633b55055ff/Untitled%2010.png)

## 挂载主机目录

windows下的路径

`\\wsl$\docker-desktop-data\version-pack-data\community\docker\volumes\`

## 数据卷

`数据卷` 是一个可供一个或多个容器使用的特殊目录，它绕过 UFS，可以提供很多有用的特性：

- `数据卷` 可以在容器之间共享和重用
- 对 `数据卷` 的修改会立马生效
- 对 `数据卷` 的更新，不会影响镜像
- `数据卷` 默认会一直存在，即使容器被删除

# 安全

# Docker三驾马车

## docker compose

如果说 Dockerfile 是将容器内运行环境的搭建固化下来，那么 Docker Compose 我们就可以理解为将多个容器运行的方式和配置固化下来。

[docker compose](Docker%20dee6811f21094ba497f02633b55055ff/docker%20compose%20a113d9867383442ca21bc967ae338c89.md) 

## docker machine

## docker swarm

# Docker命令行操作

[docker命令行](Docker%20dee6811f21094ba497f02633b55055ff/docker%E5%91%BD%E4%BB%A4%E8%A1%8C%2022a3bbe33f9e4a68a8303c8032fd2095.md) 

# Docker私仓

## Nexus

## Habor

# 问题

linux中无法访问docker，需要把当前用户添加到docker用户组里

```bash
usermod -aG docker <user>
```