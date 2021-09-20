---

title: "linux网络工具汇总"
date: 2021-09-18T22:56:16+08:00
lastmod: 2021-09-19T22:56:16+08:00
draft: false
keywords: []
description: ""
tags: ["linux", "网络"]
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

汇总本人常用的linux网络命令，附带一些常见网路问题的解析。

<!--more-->

---

本文涉及命令：

- [ip](#网络接口), [ifconfig](#网络接口), [ethtool](#网络接口), [sar](#网络接口)

- [route](#命令), [arp](#ARP表)

- [nslookup](#nslookup), [dig](#dig)

- [ping](#网络层), [arping](#网络层), [traceroute](#网络层), [mtr](#网络层)

- [ssh](#传输层), [nc](#传输层)

- [ss](#TCP链路), [netstat](#TCP链路)

- [tcpdump](#TCP报文)

# 主机配置



## 网络接口

```bash
网络接口的配置文件：/etc/sysconfig/network-scripts/ #配置文件
查看双网卡绑定：cat /proc/net/bonding/bond0
```

`ip` or `ifconfig`

> 查看或配置网络几口

```bash
ip a
```

`ethtool`

> 查看网络接口的参数

```bash
ethtool eth0
'''
Settings for eth0:
        Supported ports: [ TP ]
        Supported link modes:   10baseT/Half 10baseT/Full 
                                100baseT/Half 100baseT/Full 
                                1000baseT/Full 
        Supported pause frame use: No
        Supports auto-negotiation: Yes
        Supported FEC modes: Not reported
        Advertised link modes:  10baseT/Half 10baseT/Full 
                                100baseT/Half 100baseT/Full 
                                1000baseT/Full 
        Advertised pause frame use: No
        Advertised auto-negotiation: Yes
        Advertised FEC modes: Not reported
        Speed: 1000Mb/s
        Duplex: Full
        Port: Twisted Pair
        PHYAD: 0
        Transceiver: internal
        Auto-negotiation: on
        MDI-X: off (auto)
Cannot get wake-on-lan settings: Operation not permitted
        Current message level: 0x00000007 (7)
                               drv probe link
        Link detected: yes
'''
```



`sar`

> 查看各网络接口的历史吞吐

```bash
sar -n DEV
sar -n ALL
```



## 路由表

> 储存在主机和路由器上，记录对端ip和下一节点的对应关系、

### 命令

```bash
netstat -rn
route -n 
ip route


Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.139.128.1    0.0.0.0         UG    0      0        0 eth0  #默认路由
10.0.0.10       10.139.128.1    255.255.255.255 UGH   0      0        0 eth0  #主机路由
10.139.128.0    0.0.0.0         255.255.224.0   U     0      0        0 eth0  #网络路由
169.254.0.0     0.0.0.0         255.255.0.0     U     1002   0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
```

| 字段        |                             说明                             |
| :---------- | :----------------------------------------------------------: |
| Destination | 目标网络或目标主机。default（`0.0.0.0`）表示这个是默认网关。 |
| Gateway     | 网关地址，`0.0.0.0` 表示当前记录对应的 Destination 跟本机在同一个网段，通信时不需要经过网关 |
| Genmask     | Destination 的网络掩码，Destination 为主机时设置为 `255.255.255.255`，为默认路由时设置为 `0.0.0.0` |
| Flags       |                    含义参考表格后面的解释                    |
| Metric      | 路由距离，到达指定网络所需的中转数，是大型局域网和广域网设置所必需的 （不在Linux内核中使用。） |
| Ref         |           路由项引用次数 （不在Linux内核中使用。）           |
| Use         |                 此路由项被路由软件查找的次数                 |
| Iface       |                           网络接口                           |

flags：

- U 路由是活动的
- H 目标是个主机
- G 需要经过网关
- R 恢复动态路由产生的表项
- D 由路由的后台程序动态地安装
- M 由路由的后台程序修改
- ! 拒绝路由

### 解析

```bash
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.139.128.1    0.0.0.0         UG    0      0        0 eth0  #默认路由
10.0.0.10       10.139.128.1    255.255.255.255 UGH   0      0        0 eth0  #主机路由
10.139.128.0    0.0.0.0         255.255.224.0   U     0      0        0 eth0  #网络路由
169.254.0.0     0.0.0.0         255.255.0.0     U     1002   0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
```

当需要发送一个ip报文时，linux会根据对端ip和Destination字段寻找匹配的路由规则。这里举两个例子。

对端ip：`169.254.3.1`

- 匹配的路由规则：Destination = `169.254.0.0`
- 出口网络接口：eth0
- 不经过网关

对端ip：`30.11.3.3`

- 匹配的路由规则：Destination = `0.0.0.0`
- 出口网络接口：eth0
- 发送至网关

linux的路由原则：

- 如果对端ip在路由表中有对应规则，则从该规则对应网口发出
- 如果对端ip在路由表中无对应规则，按照默认规则，会发往网关。设置网关ip时，网关ip也必须在路由表中有对应规则。即要明确要从哪个网口发送至网关。

## ARP表

> 储存在主机和路由器上，记录ip地址和mac地址的对应关系

`arp -a` 查看arp表



## DNS配置

`/etc/resolv.conf`



## TCP相关参数

随机分配端口范围：/proc/sys/net/ipv4/ip_local_port_range

time_out状态的端口是否复用：/proc/sys/net/ipv4/tcp_tw_reuse



# ip/tcp相关工具





## DNS

### `nslookup`

```bash
nslookup baidu.com
'''
Server:         127.0.0.53
Address:        127.0.0.53#53

Non-authoritative answer:
www.baidu.com   canonical name = www.a.shifen.com.
Name:   www.a.shifen.com
Address: 36.152.44.95
Name:   www.a.shifen.com
Address: 36.152.44.96
'''
```



### `dig`

```bash
dig www.baidu.com
'''
www.baidu.com.  224 IN CNAME www.a.shifen.com.
www.a.shifen.com. 224 IN A 36.152.44.95
www.a.shifen.com. 224 IN A 36.152.44.96
'''

# 指定的DNS服务器查询
dig @8.8.8.8 baidu.com
```



## 连通性测试

### 网络层

`ping`

> 全网络测试机器的可达性，ICMP协议

`arping`

> 本地网络的可达性，不经过路由器，ARP协议

由于arping命令基于ARP广播机制，所以arping命令只能测试同一网段或子网的网络主机的连通性，ping命令则是基于ICMP协议，是可以路由的，所以使用ping命令可以测试任意网段的主机网络连通性。

`traceroute`

> 显示中间经过的网络设备，ICMP协议

如果在局域网中的不同网段之间，我们可以通过traceroute 来排查问题所在，是主机的问题还是网关的问题。有时我们traceroute一台主机时，会看到有一些行是以星号表示的。出现这样的情况，可能是防火墙封掉了ICMP的返回信息。

```bash
traceroute www.58.com
'''
traceroute to www.58.com (211.151.111.30), 30 hops max, 40 byte packets
 1  unknown (192.168.2.1)  3.453 ms  3.801 ms  3.937 ms
 2  221.6.45.33 (221.6.45.33)  7.768 ms  7.816 ms  7.840 ms
 3  221.6.0.233 (221.6.0.233)  13.784 ms  13.827 ms 221.6.9.81 (221.6.9.81)  9.758 ms
 4  221.6.2.169 (221.6.2.169)  11.777 ms 122.96.66.13 (122.96.66.13)  34.952 ms 221.6.2.53 (221.6.2.53)  41.372 ms
 5  219.158.96.149 (219.158.96.149)  39.167 ms  39.210 ms  39.238 ms
 6  123.126.0.194 (123.126.0.194)  37.270 ms 123.126.0.66 (123.126.0.66)  37.163 ms  37.441 ms
 7  124.65.57.26 (124.65.57.26)  42.787 ms  42.799 ms  42.809 ms
 8  61.148.146.210 (61.148.146.210)  30.176 ms 61.148.154.98 (61.148.154.98)  32.613 ms  32.675 ms
 9  202.106.42.102 (202.106.42.102)  44.563 ms  44.600 ms  44.627 ms
10  210.77.139.150 (210.77.139.150)  53.302 ms  53.233 ms  53.032 ms
11  211.151.104.6 (211.151.104.6)  39.585 ms  39.502 ms  39.598 ms
12  211.151.111.30 (211.151.111.30)  35.161 ms  35.938 ms  36.005 ms
'''

# 记录按序列号从1开始，每个纪录就是一跳 ，每跳表示一个网关，
# 我们看到每行有三个时间，单位是ms，其实就是-q的默认参数。
# 探测数据包向每个网关发送三个数据包后，网关响应后返回的时间；
# 如果用traceroute -q 4 www.58.com，表示向每个网关发送4个数据包。
```

`mtr`

> my traceroute，ICMP协议

```bash
mtr 8.8.8.8
'''
Keys:  Help   Display mode   Restart statistics   Order of fields   quit
Packets               Pings
Host                                Loss%   Snt   Last   Avg  Best  Wrst StDev
1. 121.52.213.161                    0.0%    25    0.7   2.2   0.6  13.7   3.0
2. 10.0.20.37                        0.0%    25    0.8   0.8   0.6   1.2   0.1
3. 61.50.163.249                     0.0%    24    1.2   1.7   1.1   4.8   1.0
4. bt-204-129.bta.net.cn             0.0%    24    1.2   4.3   1.0  49.5  11.1
5. 124.65.60.137                     0.0%    24    1.1   1.1   0.9   1.6   0.1
6. 61.148.156.57                     0.0%    24    2.4   2.5   1.8   9.3   1.5
7. 202.96.12.89                      0.0%    24    4.3   5.4   2.3  38.8   7.8
8. 219.158.15.14                     0.0%    24   52.1  42.4  41.3  52.1   2.2
9. 219.158.3.74                      0.0%    24   75.4  75.7  58.1  86.4   6.9
10. 219.158.96.246                    0.0%    24   34.5  33.9  33.0  37.8   1.0
11. 219.158.3.238                     0.0%    24   99.0  93.6  77.8 102.0   5.7
12. 72.14.215.130                     0.0%    24   39.1  38.3  36.3  48.9   2.9
13. 64.233.175.207                    4.2%    24   36.7  42.4  36.5  84.2  13.6
14. 209.85.241.56                     0.0%    24   36.7  43.1  36.3  91.8  16.6
209.85.241.58
15. 216.239.43.17                     0.0%    24   37.3  40.1  37.0  56.4   6.3
209.85.253.69
209.85.253.71
216.239.43.19
16. 216.239.48.238                    0.0%    24   38.5  41.6  37.1  50.3   4.6
216.239.48.234
216.239.48.226
216.239.48.230
17. google-public-dns-a.google.com    0.0%    24   37.6  37.8  37.2  39.8   0.7
'''
```

- 第一列:显示的是IP地址和本机域名，这点和traceroute很像
- 第二列:snt:10 设置每秒发送数据包的数量，默认值是10 可以通过参数 -c来指定。其中-c的说明是：–report-cycles COUNT
- 第三列:是显示的每个对应IP的丢包率
- 第四列:显示的最近一次的返回时延
- 第五列:是平均值 这个应该是发送ping包的平均时延
- 第六列:是最好或者说时延最短的
- 第七列:是最差或者说时延最常的
- 第八列:是标准偏差

### 传输层

`telnet` or `ssh`

> 查看某一端口的连通性

```bash
ssh -v 10.6.8.111 -p 80
```



`nc`

> 端口扫描

```bash
nc [options] [destination] [port]
```

- -z：只扫描开放的端口
- -n：直接使用IP地址，而不通过域名服务器
- -w<超时秒数>：设置等待连线的时间
- -v： 显示指令执行过程
- -s<来源位址> 设置本地主机送出数据包的IP地址。

```bash
nc -vz -w2 192.168.1.100 1-65535 # 扫描192.168.1.100主机的1-65535端口
'''
192.168.1.100 22 (ssh) open
192.168.1.100 19999 (dnp-sec) open
'''

nc -nvv 192.168.1.100 22 #指定端口扫描
192.168.1.100 22 (ssh) open
SSH-2.0-OpenSSH_7.4
Protocol mismatch.
Total received bytes: 40
Total sent bytes: 1

nc -vz www.baidu.com 443 -w2 # 查看从服务器到目标地址的出站端口是否被防火墙阻断
www.baidu.com [36.152.44.96] 443 (https) open 
```

常用默认端口：

- ftp: 21
- ssh: 22
- telnet: 23
- http: 80
- https: 443
- dns: 53
- snmp: 161

## TCP链路

### `netstat` or `ss`

> 查看本机通讯链路情况。ss（Socket Statistics），类似netstat，但性能更好。

详见本站文章：[使用ss查看linux套接字](/post/使用ss查看linux套接字/)



## TCP报文

详见本站文章：[使用tcpdump抓包](/post/使用tcpdump抓包/)



# 常见问题

详见本站文章：[tcp常见问题汇总](/post/tcp常见问题汇总/)

# 参考

[Linux 路由表详解及 route 命令详解](https://blog.csdn.net/kikajack/article/details/80457841)

[linux ss命令详解](https://cloud.tencent.com/developer/article/1721800)
