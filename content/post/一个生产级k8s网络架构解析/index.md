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

# Overlay 网络设计

overlay使用vxlan模式，架构如下：

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

这张图展示了一个典型的 vxlan overlay 网络架构。我们逐一分析各个组件：
**pod网络空间**

1.

**node网络空间**
2.

# Underlay 网络设计

# 和集群外网络的互通
