---
title: "一个生产级k8s网络架构解析"
date: 2026-02-01T16:33:50+08:00
lastmod: 2026-02-01T16:33:50+08:00
draft: true
keywords: []
description: ""
tags: []
categories: []
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

一个生产级的 k8s 网络架构既要同时考虑可靠性、性能和应用需求。本文以一个 vxlan 的 underlay + ipvlan 的 overlay 网络架构为例，解析其架构和设计思路。
<!--more-->

# 背景介绍

k8s 网络架构要解决的是 pod 这个虚拟网络实体的通讯问题。之所以需要虚拟pod的网络，是因为k8s集群中的pod是动态创建和销毁的，且pod可被调度到集群中的任意节点上运行，为了确保pod之间的通信不受物理网络拓扑的限制，pod的ip不能是物理ip，因为物理ip受到物理网络拓扑的限制。解决方法是虚拟出来一个逻辑网络，pod在这个逻辑网络中可以自由通讯，不受物理网络的限制。
overlay和underlay网络架构是从两个不同的思路来解决这个问题的。overlay的思路是通过把pod之间的流量封装，封装后的流量可以在物理网络中传输，到达目标节点后再解封装。underlay的思路是不进行封装，通过路由配置让pod流量可以直接在物理网络中传输，常见的就是calico的bgp模式，还有本文将要介绍的ipvlan L2模式。
从上述介绍可以看出，overlay经过封装，会有性能损失，好处是不依赖物理网络设备的特性，物理网络就像在传输普通node之间的流量一样。underlay的方案没有封装性能损失，但需要配置复杂的路由规则。
overlay和underlay只实现了集群内pod之间的通讯，如果pod访问集群外，出向通常都没问题，入向必须在pod出包时设置snat。如果是集群外访问集群内的pod，因为集群网关没有pod的路由信息，通常是无法访问。overlay由于pod ip都是集群内部私有的虚拟 ip，所以外界无法访问pod。underlay pod ip由于是集群内真实的ip，如果网关有这些ip路由信息即可访问。

# 整体网络架构

```mermaid
flowchart TB
    %% 样式定义
    classDef pod fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef kernel fill:#fff3e0,stroke:#e65100,stroke-width:2px;
    classDef ovs fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px;
    classDef phy fill:#eceff1,stroke:#455a64,stroke-width:2px;

    %% 1. Pod 空间
    subgraph PodSpace ["用户空间：容器/Pod"]
        direction TB
        PodA("Pod A (10.20.1.x)"):::pod
        PodB("Pod B (Local)"):::pod
    end

    %% 2. Linux 内核空间
    subgraph HostKernel ["Linux 内核空间 (Network Namespace)"]
        direction TB
        subgraph VirtualInterfaces ["虚拟接口 (L3 接入)"]
            VethA["veth pair (upvx...)"]:::kernel
            VethB["veth pair (upvx...)"]:::kernel
            IPVS["kube-ipvs0 (Service VIP)"]:::kernel
        end

        RouteTable{"Linux 路由表/Netfilter"}:::kernel
        
        subgraph OverlayStack ["Overlay 协议栈"]
            VxlanDev["vxlan.2 (VTEP)"]:::kernel
        end
    end

    %% 3. OVS 空间
    subgraph OVSLayer ["OVS 层 (Open vSwitch)"]
        direction TB
        subgraph InternalPorts ["OVS Internal Ports (宿主机网关)"]
            BizPort["biz (业务/Underlay传输)"]:::ovs
            CtlPort["ctl (控制面 K8s API/Overlay传输)"]:::ovs
            MgmPort["mgm (管理面 SSH)"]:::ovs
        end

        Bridge["OVS 网桥 (br-bond0 / ovs-system)"]:::ovs
    end

    %% 4. 物理层
    subgraph PhyLayer ["物理层 (Physical & Bond)"]
        Bond["bond0 (LACP聚合)"]:::phy
        Nic1["ens5f0np0"]:::phy
        Nic2["ens7f0np0"]:::phy
    end

    %% 连接关系
    PodA --- VethA
    PodB --- VethB
    
    %% 内核互联
    VethA -->|L3 路由| RouteTable
    VethB -->|L3 路由| RouteTable
    IPVS -.->|DNAT/负载均衡| RouteTable
    
    RouteTable -->|跨主机流量| VxlanDev
    VxlanDev -- "UDP封装 (Outer IP)" --> RouteTable
    
    %% 内核到 OVS 的桥接点
    RouteTable -->|默认路由流量| BizPort
    RouteTable -->|API 流量| CtlPort
    RouteTable -->|管理流量| MgmPort

    %% OVS 内部连接
    BizPort --- Bridge
    CtlPort --- Bridge
    MgmPort --- Bridge
    
    %% OVS 到物理
    Bridge --- Bond
    Bond --- Nic1
    Bond --- Nic2

    %% 备注
    linkStyle 0,1 stroke-width:2px,stroke:01579b;
```

这张图展示了一个典型的 vxlan overlay 网络架构。主要组件如下：

1. veth pair：overlay pod和主机内核网络空间的连接接口，pod侧的veth接口分配pod ip地址，主机侧的veth接口不分配ip地址。
2. kube-ipvs0：k8s集群内service的vip接口，负责service的负载均衡和dnat功能。
3. vxlan.2：vxlan协议栈接口，负责pod间流量的封装和解封装。
4. OVS网桥：open vswitch虚拟交换机，本文中是根据mac地址进行转发，把bond0和三个内部网络接口连接在一起。
5. bond0：物理网卡聚合接口，负责物理网络的连接。
6. mgm、ctl、biz：分别负责管理面、控制面和业务面的流量隔离。
7. biz分为多个vlan，用于隔离underlay多个网段的流量，biz为trunk口，各个biz.vlanid为access口。

> 从这个设计可以看出，就算是同主机的pod互相访问，只要是网段不通，所有流量会出站到物理网络上的网关再回来。在本机路由表没有打通 Overlay 和 Underlay 网段的情况下，这种跨平面的流量会冲向物理网关。

# Overlay 网络设计

本文中的overlay使用vxlan方案。下文将解析 overlay网络出站和入站过程。

## overlay pod 出站流程分析

**pod网络空间到主机网络空间**
从pod命名空间发出的包，同样会先经过路由判断，因为pod ip的子网掩码配置为32，所以必然会发送到网关，路由规则会给网关配置scope link，如下所示：

```bash
# pod 内 route
default via 169.254.1.1 dev eth0 
169.254.1.1 dev eth0 scope link  # <--- 关键行

# pod ip
3: eth0@if91: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1450 qdisc noqueue 
    link/ether 3e:7c:ce:7d:a4:88 brd ff:ff:ff:ff:ff:ff
    inet 10.20.9.60/32 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::3c7c:ceff:fe7d:a488/64 scope link 
       valid_lft forever preferred_lft forever
```

scope link的作用是告诉内核，这个路由是直接连接的，不用管子网掩码。因为pod和主机网络空间是通过veth pair连接的，veth pair本质上是一个二层直连链路，所以需要配置scope link。
反过来，node上配置的overlay veth 接口的路由规则也设置了scope link，流量经过vxlan解封装后通过路由直接发给pod的veth，如下所示：

```bash
10.20.9.41 dev upvx59cca7c21fa scope link 
10.20.9.60 dev upvx4279f78e5dc scope link 
10.20.9.72 dev upvx9e4d48a9851 scope link 
10.20.9.73 dev upvxa892bdffd39 scope link 
10.20.9.74 dev upvx7c566f2b768 scope link 
```

linux 内核对数据包的处理流程都是一样的，先查路由表，根据子网掩码判断是否是同网段二层转发，如果是同网段就会直接把target mac设置为目标mac地址，然后发往对应的接口。如果不是同网段，就把target mac设置为网关mac地址，然后发往网关接口。
完成的流程图如下所示：

```mermaid
graph TD
    %% 定义样式
    classDef pod fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef host fill:#fff3e0,stroke:#e65100,stroke-width:2px;
    classDef device fill:#f3e5f5,stroke:#4a148c,stroke-dasharray: 5 5;
    classDef decision fill:#fff9c4,stroke:#fbc02d,shape:rhombus;

    subgraph Pod_NS ["Pod Namespace (10.20.9.60)"]
        direction TB
        App["应用发起请求"]:::pod
        PodRoute["Pod 内部路由表查询"]:::pod
        Packet_Encap["L2 封装 (ARP / Proxy ARP)"]:::pod
        Pod_Eth0("Pod 网卡：eth0"):::device
    end

    subgraph Channel ["跨命名空间连接"]
        Veth_Pipe[["Veth Pair 虚拟管道"]]:::device
    end

    subgraph Host_NS ["Host Namespace (宿主机)"]
        direction TB
        Host_Veth("宿主机端网卡：upvx4279..."):::device
        HostRoute["宿主机路由表查询"]:::host
        Route_Decision{"目标 IP 判断"}:::decision
        
        Path_Overlay["Overlay 目的地"]:::host
        Path_Internet["外网目的地 (NAT)"]:::host
        Path_Local["本机 / 回包"]:::host
        
        GW_VXLAN("VXLAN 接口 (vxlan.2)"):::device
        GW_Biz("物理/Bond 接口 (biz)"):::device
    end

    %% 流程连接
    App -->|发送数据包| PodRoute
    PodRoute -->|命中 default via 169.254.1.1| Packet_Encap
    
    Packet_Encap -->|目标 MAC 设为宿主机 Veth| Pod_Eth0
    Pod_Eth0 -->|进入管道| Veth_Pipe
    Veth_Pipe -->|流出管道| Host_Veth
    
    Host_Veth -->|L3 接收| HostRoute
    HostRoute --> Route_Decision
    
    Route_Decision -->|目标是其他 Node Pod| Path_Overlay
    Path_Overlay -->|Next Hop: 10.20.x.x| GW_VXLAN
    
    Route_Decision -->|目标是外网| Path_Internet
    Path_Internet -->|SNAT / Masquerade| GW_Biz
    
    Route_Decision -->|目标是 Pod 自身| Path_Local
```

### vxlan 封装流程解析

目标是 overlay pod 的流量，会路由到 vxlan 设备进行封装。路由表如下所示：

```bash
ip route 
# 其他 vtep 节点 overlay pod 路由
10.20.0.0/25 via 10.20.0.0 dev vxlan.2 onlink 
10.20.0.128/25 via 10.20.0.128 dev vxlan.2 onlink 
10.20.1.0/25 via 10.20.1.0 dev vxlan.2 onlink 
10.20.1.128/25 via 10.20.1.128 dev vxlan.2 onlink 
10.20.2.0/25 via 10.20.2.0 dev vxlan.2 onlink 
10.20.2.128/25 via 10.20.2.128 dev vxlan.2 onlink 
10.20.3.128/25 via 10.20.3.128 dev vxlan.2 onlink 
10.20.4.0/25 via 10.20.4.0 dev vxlan.2 onlink 
10.20.4.128/25 via 10.20.4.128 dev vxlan.2 onlink 
10.20.5.0/25 via 10.20.5.0 dev vxlan.2 onlink 
10.20.5.128/25 via 10.20.5.128 dev vxlan.2 onlink 
10.20.6.0/25 via 10.20.6.0 dev vxlan.2 onlink 
10.20.6.128/25 via 10.20.6.128 dev vxlan.2 onlink 
10.20.7.0/25 via 10.20.7.0 dev vxlan.2 onlink 
10.20.7.128/25 via 10.20.7.128 dev vxlan.2 onlink 
10.20.8.0/25 via 10.20.8.0 dev vxlan.2 onlink 

# 本节点 overlay pod 路由
10.20.9.41 dev upvx59cca7c21fa scope link 
10.20.9.60 dev upvx4279f78e5dc scope link 
10.20.9.72 dev upvx9e4d48a9851 scope link 
10.20.9.73 dev upvxa892bdffd39 scope link 
10.20.9.74 dev upvx7c566f2b768 scope link 
10.20.9.75 dev upvx2e08d01829e scope link 
10.20.9.101 dev upvx1cd518c52ac scope link 

# 本节点 vxlan interface
36: vxlan.2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN group default 
    link/ether 1a:71:2e:f8:db:6e brd ff:ff:ff:ff:ff:ff
    inet 10.20.9.0/32 scope global vxlan.2
       valid_lft forever preferred_lft forever
```

内核在把数据包发送到vxlan接口前，需要构建二层包，会先根据下一跳的vtep ip去查询arp表(`ip neigh show`)，获取对端vtep的mac地址，然后把target mac设置为vtep的mac地址，src mac 设置为vxlan接口的mac地址，最后把构建好的二层包发往vxlan接口。vxlan需要在原始的二层包上封装udp的三层包，首先会根据target mac地址，查询vxlan的fdb表，查找到对端的node ip，外层ip头的src是本节点vtep ip（本节点的ctl 接口ip），dst是对端节点vtep ip（本例中是对端node的ctl接口ip），最后根据路由，发往ctl接口进入ovs进行转发。网络包的结构如下所示：
**pod ns 中的原始包**

```plain
+---------------------------------------------------------------+
|                        IP Header (L3)                         |
+-----------------------+-----------------------+---------------+
| Src IP: 10.20.9.60    | Dst IP: 10.20.6.10    | Payload (TCP) |
+-----------------------+-----------------------+---------------+
```

**宿主机内核根据路由和arp表，构建二层包**

```plain
 构建好的二层帧 (Inner Frame)
+=================================================================================+
|                              Ethernet Header (L2)                               |
+---------------------------+---------------------------+-------------------------+
| Dst MAC (Target MAC)      | Src MAC (VXLAN MAC)       | EtherType               |
| 66:66:66:66:66:66         | aa:aa:aa:aa:aa:aa         | 0x0800 (IPv4)           |
+---------------------------+---------------------------+-------------------------+
|                                                                                 |
|       +---------------------------------------------------------------+         |
|       |                        IP Header (L3)(pod原始包)               |         |
|       +-----------------------+-----------------------+---------------+         |
|       | Src IP: 10.20.9.60    | Dst IP: 10.20.6.10    | Payload       |         |
|       +-----------------------+-----------------------+---------------+         |
|                                                                                 |
+=================================================================================+
```

**vxlan 查询FDB，封装后的三层包**

```plain
 VXLAN 封装后的完整报文
+=======================================================================================================================+
|                                              Outer IP Header (Underlay L3)                                            |
+-----------------------------------+-----------------------------------+-----------------------+-----------------------+
| Src IP: 10.186.152.114 (本机 ctl) | Dst IP: 192.168.152.101 (对端 Node) | Protocol: 17 (UDP)    | ...                   |
+-----------------------------------+-----------------------------------+-----------------------+-----------------------+
|                                                                                                                       |
|   +---------------------------------------+                                                                           |
|   |         UDP Header (L4)               |                                                                           |
|   +-------------------+-------------------+                                                                           |
|   | Src Port: Random  | Dst Port: 4789    |                                                                           |
|   +-------------------+-------------------+                                                                           |
|                                                                                                                       |
|       +---------------------------------------+                                                                       |
|       |           VXLAN Header                |                                                                       |
|       +-------------------+-------------------+                                                                       |
|       | Flags: 0x08       | VNI: 2            |                                                                       |
|       +-------------------+-------------------+                                                                       |
|                                                                                                                       |
|           +---------------------------------------------------------------------------------+                         |
|           |                          Inner Ethernet Frame (L2)(node封装的原始二层包)           |                         |
|           +---------------------------+---------------------------+-------------------------+                         |
|           | Dst MAC (VTEP)            | Src MAC (VXLAN)           | Payload (Original IP)   |                         |
|           | 66:66:66:66:66:66         | aa:aa:aa:aa:aa:aa         | Src: 10.20.9.60 ...     |                         |
|           +---------------------------+---------------------------+-------------------------+                         |
|                                                                                                                       |
+=======================================================================================================================+
```

**FDB 和 ARP 表内容示例**

```bash
bridge fdb show dev vxlan.2
# target vtep mac -> target vtep ip 
xx:xx:xx:xx:xx:xx dst 10.186.152.107 self permanent
xx:xx:xx:xx:xx:xx dst 10.186.152.101 self permanent
xx:xx:xx:xx:xx:xx dst 10.186.152.111 self permanent
xx:xx:xx:xx:xx:xx dst 10.186.152.103 self permanent
...

ip -4 neigh show
# ip -> mac
10.20.5.128 dev vxlan.2 lladdr xx:xx:xx:xx:xx:xx PERMANENT
...

```

overlay的流量关键过程是vxlan封装，其中涉及到路由表、arp表和vxlan的fdb表的查询，总结如下：

| 阶段        | 查表名称   | 命令示例     | 输入 Key                     | 输出 Value                         | 作用                                        |
| ----------- | ---------- | ------------ | ---------------------------- | ---------------------------------- | ------------------------------------------- |
| **L3 路由** | 系统路由表 | `ip route`   | 目标 Pod IP (`10.20.6.10`)   | **下一跳 VTEP IP** (`10.20.6.0`)   | 确定走哪个虚拟接口 (`vxlan.2`) 和逻辑网关。 |
| **L2 解析** | ARP/邻居表 | `ip neigh`   | 下一跳 VTEP IP (`10.20.6.0`) | **对端 VTEP MAC** (`66:66:...`)    | 为内层数据帧填充目标 MAC 地址。             |
| **转发表**  | FDB 表     | `bridge fdb` | 对端 VTEP MAC (`66:66:...`)  | **对端 Node IP** (`192.168.1.200`) | 为外层 VXLAN 报文填充目标物理 IP。          |

出站整体流程如下：

```mermaid
sequenceDiagram
    autonumber
    participant Pod as "源 Pod (Container)"
    participant Veth as "宿主机 veth (upvx)"
    participant Routing as "Linux 路由/Netfilter"
    participant Vxlan as "VXLAN 设备 (Encap)"
    participant BizIf as "OVS 端口 (ctl)"
    participant OVSBr as "OVS 网桥 (Switching)"
    participant PhyBond as "物理 Bond0"

    Note over Pod, PhyBond: 场景：容器访问跨节点 IP (例如 10.20.4.5)

    Pod->>Veth: 发送原始 IP 包 (Src:PodIP, Dst:TargetPodIP)
    Veth->>Routing: 数据包进入宿主机网络栈
    
    Routing->>Routing: 查路由表
    Note right of Routing: 命中路由：via 10.20.4.0 dev vxlan.2
    Note right of Routing: 查询arp表，组装二层包
    Note right of Routing: src mac=vxlan mac，target mac=target vtep mac

    Routing->>Vxlan: 转发给 VXLAN 设备
    Vxlan->>Vxlan: 封装数据包 (UDP Tunnel)
    Note right of Vxlan: 增加外层头：Src=HostIP(ctl), Dst=RemoteHostIP

    Vxlan->>Routing: 封装后的 UDP 包回到协议栈
    Routing->>Routing: 再次查路由 (外层 IP)
    Note right of Routing: 命中默认路由：via 10.186.152.254 dev ctl

    Routing->>BizIf: 从 ctl 接口发出
    Note right of BizIf: 此处从 Linux 内核态“进入”OVS 域

    BizIf->>OVSBr: 数据进入 OVS 数据平面
    OVSBr->>OVSBr: 查 OVS 流表 (FDB/Flows)
    
    OVSBr->>PhyBond: 转发至物理出口
    PhyBond->>PhyBond: LACP 哈希选择子网卡
    PhyBond-->>PhyBond: 发送至物理交换机
```

> 如果需要访问的overlay pod就在本节点，路由规则会直接匹配到本节点的 overlay veth 接口，流量不会经过 vxlan 封装，直接发往本节点的 overlay pod。

### SNAT 和 conntrack

overlay pod 访问集群外网络，出去的流量不会经过vxlan封装，路径和物理节点访问外网一样。唯一的问题是src ip是overlay的ip，集群外没有这个ip的路由信息。为了解决这个问题，会对overlay pod访问非overlay网段的流量做snat，通常是masquerade，把src ip改为节点的物理ip。这样集群外的主机就能正确回复流量回到节点，节点再根据conntrack表把流量转发回pod。
大致流程如下：

1. overlay pod发送的流量到达节点内核网络空间，查询路由信息后获取下一跳的ip地址（不会经过vxlan）。
2. iptables 捕获包，根据规则判断包的src ip是overlay网段，目的ip不是overlay网段，执行snat，把src ip改为节点物理ip。
3. conntrack 会记录这个连接的原始src ip和snat后的src ip映射关系，等到回复包回来时，根据这个映射关系把流量转发回pod。

```bash
# 在 *mangle 表中，来自 10.20.0.0/16（Overlay 网段）的报文被打上 0x100 标记
-A PREROUTING -s 10.20.0.0/16 ... -j MARK --set-xmark 0x100/0x100

# 在 *nat 表中，带有 0x100 标记的报文进入 UPCS-MASQUERADE 链处理
-A POSTROUTING -m mark --mark 0x100/0x100 -j UPCS-MASQUERADE 

# 如果目标ip是overlay网段，直接返回，不做snat，否则执行masquerade
# masquerade是一种动态 SNAT，它将数据包的源 IP (Pod IP) 修改为宿主机出口网卡的 IP 地址。
-A UPCS-MASQUERADE -d 10.20.0.0/16 ... -j RETURN
-A UPCS-MASQUERADE -j MASQUERADE
```

# Underlay 网络设计

## underlay pod 出站流程分析

### pod 命名空间 --> biz 接口

**pod 内网络协议栈：**

1. Pod 内部路由网关指向物理网关（10.186.155.30）。
2. Pod 内网络栈匹配到路由 scope link，意味着网关在二层直连网络上，发起 ARP 请求获取网关 MAC。
3. 封装好二层包头（Dst MAC=Gateway）后，通过 eth0 发出。

> eth0@if41 是 IPvlan 子设备，pod 内网络协议栈会根据路由信息把所有流量都通过 eth0@if41发出

```bash
# underlay pod 容器内接口信息
2: eth0@if41: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue 
    link/ether 8e:78:9c:32:b5:72 brd ff:ff:ff:ff:ff:ff
    inet 10.186.155.6/27 brd 10.186.155.31 scope global eth0
# 路由信息
default via 10.186.155.30 dev eth0 
10.186.155.0/27 dev eth0 scope link  src 10.186.155.6 
```

**IPvlan + vlan：**

1. eth0 作为 IPvlan 的子接口，其本身的核心操作函数被注册为 IPvlan 的驱动函数，所有发往 eth0 的流量都会被 IPvlan 驱动捕获。
2. IPvlan 驱动捕获该流量，直接将其挂载到 Master 接口 vlan.1155 的发送队列。
3. 由于 vlan.1155 是 biz 的 VLAN 子接口，Linux 内核在发包时会自动打上 VLAN Tag 1155，发送给 vlan master 接口（biz）。

> 出站时，IPvlan无需对数据包做改动，直接把数据包从 pod 命名空间递送给 node 命名空间的 IPvlan master 接口（vlan.1155)

```bash
# node节点 vlan 接口信息
39: vlan.1156@biz: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 8e:78:9c:32:b5:72 brd ff:ff:ff:ff:ff:ff
40: vlan.1157@biz: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 8e:78:9c:32:b5:72 brd ff:ff:ff:ff:ff:ff
41: vlan.1155@biz: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 8e:78:9c:32:b5:72 brd ff:ff:ff:ff:ff:ff
98: vlan.1158@biz: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 8e:78:9c:32:b5:72 brd ff:ff:ff:ff:ff:ff

```

**数据包结构示例：**

pod 命名空间内，网路协议栈通过 arp 获取物理网关的 mac 地址，封装二层包头：

```plain
[ 原始二层以太网帧 (Untagged) ]
+---------------------+---------------------+-----------+-------------------------+
| Dst MAC             | Src MAC             | EtherType | L3 IP Header            |
| (Gateway MAC)       | (Shared Parent MAC) | IPv4      | Src: 10.186.155.6       |
| aa:bb:cc:dd:ee:ff   | 30:b9:30:3d:84:8d   | 0x0800    | Dst: 8.8.8.8            |
+---------------------+---------------------+-----------+-------------------------+
```

vlan.1155 打上 VLAN Tag 后：

```plain
[ 插入 VLAN Tag 的帧 (Tagged) ]
+---------------------+---------------------+===========+-----------+-------------+
| Dst MAC             | Src MAC             | 802.1Q    | EtherType | L3 IP Header|
| (Gateway MAC)       | (Shared Parent MAC) | VLAN ID   | IPv4      | (不变)      |
| aa:bb:cc:dd:ee:ff   | 30:b9:30:3d:84:8d   | 1155      | 0x0800    |             |
+---------------------+---------------------+===========+-----------+-------------+
                                                 ^
                                                 |
                                         Linux 内核自动插入
```

### OVS --> 物理网关

1. 已经被标记 vlan tag 的流量进入 OVS 的 biz 端口。
2. OVS 依据标准二层交换逻辑处理网络包：

     * 学习 Source MAC（Pod MAC）与 biz 端口的映射。
     * 查找 Destination MAC（Gateway MAC）。若表中存在（指向 bond0），则单播转发；若不存在，则泛洪。
3. 最终流量经由 bond0 上联物理网口发出。

> 数据包头在 OVS 中没有变化，OVS 中只转发

### pod 的入站流程分析

1. 回包到达 vlan.1155（Master 设备）。

2. IPvlan 驱动作为Master 设备上的 hook 截获流量。

3. 读取网络包的三层头信息，获取Target IP ，查询内部是否有子接口匹配。

4. IPvlan 直接将包注入对应 Pod 的接收队列，完成 L3 到 L2 的分发。

**IPvlan 内部的映射关系示意图：**

| Key (Dst IP)    | Value (Target Device)     |
| --------------- | ------------------------- |
| `10.186.155.6`  | -> Pod A Namespace / eth0 |
| `10.186.155.32` | -> Pod B Namespace / eth0 |
| `10.186.155.33` | -> Pod C Namespace / eth0 |
| (No Match)      | -> Host (vlan.1155)       |

**数据包结构示例：**
vlan.1155 接收到回包，剥离 VLAN Tag 后，IPvlan 驱动捕获到这个包进行 L3 分流：

```plain
[ 入站的 VLAN 帧 ]
+---------------------+---------------------+===========+-----------+-------------------------+
| Dst MAC             | Src MAC             | 802.1Q    | EtherType | L3 IP Header            |
| (Shared Parent MAC) | (Gateway MAC)       | VLAN ID   | IPv4      | Src: 8.8.8.8            |
| 30:b9:30:3d:84:8d   | aa:bb:cc:dd:ee:ff   | 1155      | 0x0800    | Dst: 10.186.155.6 (Pod) |
+---------------------+---------------------+===========+-----------+-------------------------+


[ Hook 处理中的状态 (逻辑视角) ]
                                         (查看此处 IP 进行分流)
                                                  |
                                                  v
+---------------------+---------------------+-----------+-------------------------+
| Dst MAC             | Src MAC             | EtherType | L3 IP Header            |
| ...                 | ...                 | 0x0800    | Dst: 10.186.155.6       |
+---------------------+---------------------+-----------+-------------------------+


[ Pod 内收到的最终标准帧 (Untagged) ]
+---------------------+---------------------+-----------+-------------------------+
| Dst MAC             | Src MAC             | EtherType | L3 IP Header            |
| (Shared Parent MAC) | (Gateway MAC)       | IPv4      | Src: 8.8.8.8            |
| 30:b9:30:3d:84:8d   | aa:bb:cc:dd:ee:ff   | 0x0800    | Dst: 10.186.155.6       |
+---------------------+---------------------+-----------+-------------------------+
```

**整体流程如下：**

```mermaid
graph TD
    %% 定义样式
    classDef ns fill:#f9f9f9,stroke:#333,stroke-width:2px;
    classDef device fill:#e1f5fe,stroke:#0277bd,stroke-width:2px,rx:5,ry:5;
    classDef phy fill:#fff3e0,stroke:#ef6c00,stroke-width:2px,rx:5,ry:5;

    subgraph PodNS ["Pod Namespace (容器环境)"]
        direction TB
        P_Route["路由表 (Default Gateway: 10.186.155.30)"]
        P_Eth0["eth0@if41 (IP: 10.186.155.6)"]
    end

    subgraph Kernel ["Linux Kernel Layer"]
        Driver["IPVLAN 驱动 (Hook)"]
        Note_MAC["特性：共享 MAC 地址<br/>(8e:78:9c:32:b5:72)"]
    end

    subgraph HostNS ["Host Namespace (宿主机环境)"]
        direction TB
        H_Vlan["vlan.1155@biz (Index 41)<br/>父接口 / VLAN 映射"]
        H_Biz["biz / bond0 (聚合接口)"]
        H_Phy["Physical NICs (ens5f0np0)"]
    end

    subgraph PhysNet ["Physical Network (物理层)"]
        Switch_Port["物理交换机端口"]
        Switch_SVI["ToR 网关 (IP: 10.186.155.30)"]
    end

    %% 流量路径逻辑连接
    P_Route -->|匹配默认路由| P_Eth0
    P_Eth0 -->|"L3 出栈 (直接挂载)"| Driver
    Driver -.->|关联父接口| H_Vlan
    Driver --- Note_MAC
    
    H_Vlan -->|打上 VLAN Tag 1155| H_Biz
    H_Biz -->|L2 传输| H_Phy
    H_Phy -->|线缆传输| Switch_Port
    Switch_Port -->|三层路由转发| Switch_SVI

    %% 应用样式
    class PodNS,HostNS ns;
    class P_Eth0,H_Vlan,H_Biz,H_Phy device;
    class Switch_SVI phy;
```

## 出站和入站时序图

出站：

```mermaid
sequenceDiagram
    autonumber
    participant Pod as "Pod (eth0)"
    participant IPvlan as "IPvlan 驱动 (Kernel)"
    participant Master as "Master 接口 (vlan.1155)"
    participant OVS as "OVS 网桥 (biz/bond0)"
    participant PhyNet as "物理网关 (Gateway)"

    Note over Pod, PhyNet: 阶段一：Egress 发包准备
    Pod->>Pod: 路由查找 (Default via Gateway)
    Pod->>Pod: 匹配 Scope Link，发起 ARP 请求
    Pod->>Pod: 封装二层头 (Dst MAC = Gateway)
    
    Note over Pod, IPvlan: 阶段二：IPvlan 出站处理
    Pod->>IPvlan: 通过 eth0 发出数据包
    note right of IPvlan: 不需要 Hook<br/>直接执行驱动代码
    IPvlan->>Master: 挂载到发送队列 (Queue Grafting)
    
    Note over Master, OVS: 阶段三：VLAN 与 OVS 转发
    Master->>OVS: 自动打上 VLAN Tag 1155 并注入 biz 端口
    OVS->>OVS: 学习源 MAC (Pod MAC) -> biz
    OVS->>OVS: 查表目的 MAC (Gateway) -> bond0
    OVS->>PhyNet: 经 bond0 发送至物理网络

    rect rgb(240, 248, 255)
        Note over PhyNet, Pod: 阶段四：Ingress 入站回包
        PhyNet-->>OVS: 回包到达物理口
        OVS-->>Master: 转发至 vlan.1155 (Tag Stripped/Passed)
        Master->>IPvlan: 触发 RX Handler (Hook 截获)
        note right of IPvlan: 关键逻辑：L3 Demux<br/>(根据目的 IP 查表)
        IPvlan->>Pod: 注入 Pod 接收队列
    end
```



## 网络层面的二层架构

使用 IPvlan L2 模式，配合 vlan 和 OVS，实现了一个扁平化的大二层 Underlay 网络。其中 Node 节点本身担任交换机角色，作用是把调度到本 Node 上的 Pod 接入这个多 vlan 的二层网络。从网络层面看，此 Underlay 网络如下图所示：

```mermaid
flowchart TB
  %% --- 样式定义 ---
  classDef phySwitch fill:#cfd8dc,stroke:#37474f,stroke-width:3px,color:#000;
  classDef nodeBox fill:#eceff1,stroke:#607d8b,stroke-width:2px,stroke-dasharray: 0;
  classDef nicLayer fill:#b0bec5,stroke:#455a64,stroke-width:2px,color:#000;
  classDef podNode fill:#fff,stroke:#333,stroke-width:1px;
  
  %% VLAN 颜色定义 (用于区分 VLAN 域)
  classDef vlan1155 fill:#e3f2fd,stroke:#1565c0,stroke-dasharray: 5 5;
  classDef vlan1156 fill:#fff3e0,stroke:#ef6c00,stroke-dasharray: 5 5;
  classDef vlan1157 fill:#e8f5e9,stroke:#2e7d32,stroke-dasharray: 5 5;
  classDef vlan1158 fill:#f3e5f5,stroke:#7b1fa2,stroke-dasharray: 5 5;

  %% --- 顶层物理设备 ---
  CoreSwitch["Gateway / Physical Switch<br/>(Core)"]:::phySwitch

  %% --- Node 1 ---
  subgraph Node1 ["k8s-node-01"]
    direction TB
    N1_NIC["Node1 Adapter<br/>(IPVlan Master / Trunk)"]:::nicLayer
    
    %% Node1 内部的 VLAN 划分
    subgraph N1_V1155 ["VLAN 1155 (Subnet .155.x)"]
      N1_P1(Pod A1):::podNode
      N1_P2(Pod A2):::podNode
    end
    subgraph N1_V1156 ["VLAN 1156 (Subnet .156.x)"]
      N1_P3(Pod B1):::podNode
    end
    subgraph N1_V1157 ["VLAN 1157 (Subnet .157.x)"]
      N1_P4(Pod C1):::podNode
    end
    subgraph N1_V1158 ["VLAN 1158 (Subnet .158.x)"]
      N1_P5(Pod D1):::podNode
    end
    
    %% 连接关系
    N1_NIC ==> N1_V1155 & N1_V1156 & N1_V1157 & N1_V1158
  end

  %% --- Node 2 ---
  subgraph Node2 ["k8s-node-02"]
    direction TB
    N2_NIC["Node2 Adapter<br/>(IPVlan Master / Trunk)"]:::nicLayer
    
    subgraph N2_V1155 ["VLAN 1155"]
      N2_P1(Pod A3):::podNode
    end
    subgraph N2_V1156 ["VLAN 1156"]
      N2_P3(Pod B2):::podNode
      N2_P4(Pod B3):::podNode
    end
    subgraph N2_V1157 ["VLAN 1157"]
       N2_P5(Pod C2):::podNode
    end
    subgraph N2_V1158 ["VLAN 1158"]
       N2_P6(Pod D2):::podNode
    end

    N2_NIC ==> N2_V1155 & N2_V1156 & N2_V1157 & N2_V1158
  end

  %% --- Node 3 ---
  subgraph Node3 ["k8s-node-03"]
    direction TB
    N3_NIC["Node3 Adapter<br/>(IPVlan Master / Trunk)"]:::nicLayer

    subgraph N3_V1155 ["VLAN 1155"]
       N3_P1(Pod A4):::podNode
    end
    subgraph N3_V1156 ["VLAN 1156"]
       N3_P2(Pod B4):::podNode
    end
    subgraph N3_V1157 ["VLAN 1157"]
       N3_P3(Pod C3):::podNode
       N3_P4(Pod C4):::podNode
    end
    subgraph N3_V1158 ["VLAN 1158"]
       N3_P5(Pod D3):::podNode
    end

    N3_NIC ==> N3_V1155 & N3_V1156 & N3_V1157 & N3_V1158
  end
  
  %% --- 物理链路 (Trunk) ---
  CoreSwitch <== Trunk ==> N1_NIC & N2_NIC & N3_NIC

  %% 应用样式到 Subgraph (VLAN)
  class N1_V1155,N2_V1155,N3_V1155 vlan1155;
  class N1_V1156,N2_V1156,N3_V1156 vlan1156;
  class N1_V1157,N2_V1157,N3_V1157 vlan1157;
  class N1_V1158,N2_V1158,N3_V1158 vlan1158;
  class Node1,Node2,Node3 nodeBox;
```



# Overlay 和 Underlay 的互通分析

## Overlay --> Underlay 





## Underlay --> Overlay



# Q&A

Q：IPvlan 的作用是什么，为什么要用 IPvlan 实现 Underlay 网络？



Q：IPvlan 和 BGP 比，优势和劣势是什么？