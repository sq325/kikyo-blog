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
            BizPort["biz (业务/Overlay传输)"]:::ovs
            CtlPort["ctl (控制面 K8s API)"]:::ovs
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

> 从这个设计可以看出，就算是同主机的pod互相访问，只要是网段不通，都会走网关，所以流量会出站到物理网络再回来。在本机路由表没有打通 Overlay 和 Underlay 网段的情况下，这种跨平面的流量会冲向物理网关。

# Overlay 网络设计

本overlay使用vxlan方案，另外，为了overlay pod 可以访问外界非overlay网络，需要配合SNAT + conntrack实现。下文将分析 overlay pod 出站和入站的流量流程。

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

scope link的作用是告诉内核，这个路由是直接连接的，不需要经过arp解析，不用管子网掩码。因为pod和主机网络空间是通过veth pair连接的，veth pair本质上是一个二层直连链路，arp解析没有意义，所以需要配置scope link。
反过来，node上配置的overlay veth 接口的路由规则也设置了scope link，流量经过vxlan解封装后通过路由直接发给pod的veth，如下所示：

```bash
10.20.9.41 dev upvx59cca7c21fa scope link 
10.20.9.60 dev upvx4279f78e5dc scope link 
10.20.9.72 dev upvx9e4d48a9851 scope link 
10.20.9.73 dev upvxa892bdffd39 scope link 
10.20.9.74 dev upvx7c566f2b768 scope link 
```

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

overlay pod -> overlay pod 出站流程如下图：

```mermaid
sequenceDiagram
    autonumber
    participant Pod as "源 Pod (Container)"
    participant Veth as "宿主机 veth (upvx)"
    participant Routing as "Linux 路由/Netfilter"
    participant Vxlan as "VXLAN 设备 (Encap)"
    participant BizIf as "OVS 端口 (biz)"
    participant OVSBr as "OVS 网桥 (Switching)"
    participant PhyBond as "物理 Bond0"

    Note over Pod, PhyBond: 场景：容器访问跨节点 IP (例如 10.20.4.5)

    Pod->>Veth: 发送原始 IP 包 (Src:PodIP, Dst:TargetPodIP)
    Veth->>Routing: 数据包进入宿主机网络栈
    
    Routing->>Routing: 查路由表 (103_route.txt)
    Note right of Routing: 命中路由：via 10.20.4.0 dev vxlan.2

    Routing->>Vxlan: 转发给 VXLAN 设备
    Vxlan->>Vxlan: 封装数据包 (UDP Tunnel)
    Note right of Vxlan: 增加外层头：Src=HostIP(biz), Dst=RemoteHostIP

    Vxlan->>Routing: 封装后的 UDP 包回到协议栈
    Routing->>Routing: 再次查路由 (外层 IP)
    Note right of Routing: 命中默认路由：via 10.186.153.254 dev biz

    Routing->>BizIf: 从 biz 接口发出
    Note right of BizIf: 此处从 Linux 内核态“进入”OVS 域

    BizIf->>OVSBr: 数据进入 OVS 数据平面
    OVSBr->>OVSBr: 查 OVS 流表 (FDB/Flows)
    
    OVSBr->>PhyBond: 转发至物理出口
    PhyBond->>PhyBond: LACP 哈希选择子网卡
    PhyBond-->>PhyBond: 发送至物理交换机
```

1. -> vxlan: pod 通过 veth pair 出来的流量根据路由规则，如果是访问其他overlay的pod，会发往 vxlan 设备进行封装。
2. vxlan -> biz: 封装后的流量根据路由规则发往 biz 接口，进入 OVS 网桥进行转发。
3. biz -> bond0: OVS 网桥根据流表把流量发往物理网卡。



# Underlay 网络设计

# 和集群外网络的互通
