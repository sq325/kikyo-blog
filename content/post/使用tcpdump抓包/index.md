---
title: "使用tcpdump抓包"
date: 2021-09-20T22:09:52+08:00
lastmod: 2021-09-21T22:09:52+08:00
draft: false
keywords: []
description: ""
tags: ["linux", "网络", "TCP"]
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

使用场景：可以在主机获取各协议的报文，分析通讯问题的利器。
<!--more-->

---

# tcpdump选项

常用选项：

- **`-i`：指定接口**，默认为第一个网口上的所有流量               
- `-c`：限制抓取包的数量                                         
- `-D`：列出可用于抓包的接口                                     
- `-s`：指定数据包抓取的长度                                     
- `-c`：指定要抓取的数据包的数量                                 
- `-F`：从文件中读取抓包的表达式                                 
- **`-n`：不解析主机和端口号，以数值形式行显示，-nn表示ip和port都**
- `-P`：指定要抓取的包是流入还是流出的包，可以指定的值 in、out、i


输出选项：

- `-e`：输出信息中包含数据链路层头部信息               
- **`-t`：显示时间戳，tttt 显示更详细的时间**          
- `-X`：显示十六进制格式                               
- **`-v`：显示详细的报文信息，尝试 -vvv，v 越多显示越详**


# 使用实例

`tcpdump -ni [interface] [proto] [filter]`

proto:

- ether、ip、ip6、arp、icmp、tcp、udp。

filter：

`[direct] [type] [ip or port]`

- dir：表示传输的方向，可取的方式为：src、dst。
- type：表示对象的类型，比如：host、net、port、portrange，如果不指定 type 的话，默认是 host
- bool运算：or、and、not

## 按ip和port过滤

```bash
sudo tcpdump -D # 显示所有网卡
sudo tcpdump -i any -c5 -nn # 所有网卡，5个包
tcpdump -ni eth0 # eth0网卡上的数据包

# 过滤指定协议
tcpdump -ni eth0 -c 5 icmp # 5个ping包
tcpdump -ni eth0 arp # arg包
tcpdump -ni eth0 ip6 # ip6包

# 过滤ip和端口
tcpdump -ni eth0 host 192.168.1.100 # 指定IP所有的包，包括send和receive
tcpdump -ni eth0 src host 10.1.1.2 # 源端为IP的所有包
tcpdump -ni eth0 dst host 10.1.1.2 # 目标端为IP的所有包
tcpdump -ni eth0 -c 10 dst host 192.168.1.200 # 抓10个包就停止
tcpdump -ni eth0 dst port 22 #对端port的所有包
tcpdump -ni eth0 portrange 80-9000 # 指定port范围的包
tcpdump -ni eth0 net 192.168.1.0/24 # 指定网段(net)的包
tcpdump -ni eth0 src 192.168.1.100 and dst port 22 # 指定源端IP和目标端port
tcpdump -ni eth0 src net 192.168.1.0/16 and dst net 10.0.0.0/8 or 172.16.0.0/16 # 指定源端net和目标端net
tcpdump -ni eth0 src 10.0.2.4 and not dst port 22 # 指定源端IP，排除目标端PORT
tcpdump -ni eth0 'src 10.0.2.4 and (dst port 3389 or 22)' # 使用括号时要把条件用单引号囊括、
```

## 按包大小过滤

```bash
tcpdump -ni eth0 less 64 # 包小于64B
tcpdump -ni eth0 greater 64 # 包大于64B
tcpdump -ni eth0 length == 64 # 包=64B
```

## tcp包类型过滤

```bash
tcpdump -ni eth0 src host 192.168.1.100 and 'tcp[tcpflags] & (tcp-syn) !=0' # syn包
tcpdump -ni eth0 src host 192.168.1.100 and 'tcp[tcpflags] & (tcp-rst) !=0' # rst包
tcpdump -ni eth0 src host 192.168.1.100 and 'tcp[tcpflags] & (tcp-fin) !=0' # fin包
tcpdump 'tcp[tcpflags] & (tcp-syn|tcp-fin) !=0' # syn和fin包
tcpdump 'icmp[icmptype] != icmp-echo and icmp[icmptype] != icmp-echoreply' # 非 ping 类型的 ICMP 包
tcpdump 'tcp port 80 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)' # 抓取端口是 80，网络层协议为 IPv4， 并且含有数据，而不是 SYN、FIN 以及 ACK 等不含数据的数据包。（整个 IP 数据包长度减去 IP 头长度，再减去 TCP 头的长度，结果不为 0，就表示数据包有 data)
tcpdump  -ni eth0 'tcp[20:2]=0x4745 or tcp[20:2]=0x4854' # 抓取 HTTP 报文，0x4754 是 GET 前两字符的值，0x4854 是 HTTP 前两个字符的值
```

## 生成和读取pcap文件

- **w：将抓包数据保存在文件中，.cap、.pcap**
- **r：从文件中读取数据**
- C：指定文件大小，与 -w 配合使用

```bash
sudo tcpdump -i any -c10 -nn -w webserver.pcap port 80 # 保存到webserver.pcap文件中

tcpdump -n -r webserver.pcap # 解析pcap文件
tcpdump -n -r webserver.pcap tcp src host 54.204.39.132 # 增加过滤
```

## 输出解析

```bash
08:41:13.729687 IP 192.168.64.28.22 > 192.168.64.1.41916: Flags [P.], seq 196:568, ack 1, win 309, options [nop,nop,TS val 117964079 ecr 816509256], length 372

# [S.]: SYN-ACK
# [P.]: PUSH-ACK
# seq 196:568 : this packet contains bytes 196 to 568 of this flow
# ack 1: 下一个是ack 568
# win 309：window size，字节
# length 372：packet length，字节
```

- S：SYN
- F：FIN
- P：PUSH
- R：RST
- `.`：ACK

