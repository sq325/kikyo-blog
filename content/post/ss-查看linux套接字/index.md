---
title: "ss-查看linux套接字"
date: 2021-09-20T22:10:51+08:00
lastmod: 2021-09-21T22:10:51+08:00
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
hiddenFromHomePage: true
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
使用场景：在linux环境替代netstat查看socket情况。

<!--more-->

---

# 常用选项

**`ss`**

- `-n`, `--numeric`       现实数字而不是服务名
- `-r`, `--resolve`       解析服务名
- `-a`, `--all`           所有socket
- `-o`, `--options`       计时器信息
- `-e`, `--extended`      详细的socket信息
- `-m`, `--memory`        socket memory usage
- `-p`, `--processes`     process
- `-i`, `--info`          TCP information
- `-s`, `--summary`       socket usage summary

```bash
ss -tlr #把ip和端口解释为域名和协议
'''
State    Recv-Q    Send-Q     Local Address:Port             Peer Address:Port             
LISTEN   0         4096             0.0.0.0:rpc.portmapper        0.0.0.0:*                
LISTEN   0         4096        localhost%lo:domain                0.0.0.0:*                
LISTEN   0         128              0.0.0.0:ssh                   0.0.0.0:*                
LISTEN   0         4096                [::]:rpc.portmapper           [::]:*                
LISTEN   0         128                 [::]:ssh                      [::]:*                                                                 
'''
```



# 统计信息

`ss -s`

`netstat -s`

```bash
ss -s 
'''
Total: 219
TCP:   23 (estab 1, closed 1, orphaned 0, timewait 1)

Transport Total     IP        IPv6
RAW       2         0         2        
UDP       6         4         2        
TCP       22        19        3        
INET      30        23        7        
FRAG      0         0         0 
'''

netstat -s
'''
...
Ip:
    Forwarding: 1				#开启转发
    744449 total packets received		#总收包数
    3 with invalid addresses
    0 forwarded					#转发包数
    0 incoming packets discarded		#接收丢包数
    744440 incoming packets delivered		#接收包数
    927091 requests sent out			#发送包数
    2 outgoing packets dropped
    1 dropped because of missing route
Tcp:
    65775 active connection openings		#主动连接
    16547 passive connection openings		#被动连接
    7513 failed connection attempts		#失败连接
    15956 connection resets received		#接收RST数量
    1 connections established
    492001 segments received			#接收报文数
    537197 segments sent out			#发送报文数
    147803 segments retransmitted		#重传报文数
    0 bad segments received			#错误报文数
    19556 resets sent				#发送RST数量
Udp:
    242253 packets received
...
'''
```

# `ss`过滤详解

## socket类型过滤

- `-4`, --ipv4   
- `-6`, --ipv6   
- `-0`, --packet 
- `-t`, --tcp    
- `-S`, --sctp   
- `-u`, --udp    
- `-d`, --dccp  
- `-w`, --raw    
- `-x`, --unix   

```bash
ss -atn #tcp+监听的链路
ss -tln #tcp+listen

```



## socket状态过滤

`ss -ant state [filter]`

- `-l`: listening

可用的状态：`established`, `syn-sent`, `syn-recv`, `fin-wait-1`, `fin-wait-2`, `time-wait`, `closed`, `close-wait`, `last-ack`, `listening`, `closing `

```bash
ss -ant state established #已经建立的连接
ss -4n state listening
```



## socket ip过滤

`ss -ant dst/src [ip]`

```bash
ss dst 192.168.1.5
ss dst 192.168.119.113:http
ss dst 192.168.119.113:443
```

## socket端口过滤

`ss dport/sport [operation] [port]`

- dport: 目标端口
- sport：源端口

operation: le, ge, eq, ne, lt, gt

```bash
ss -ant sport lt 50 #源端口小于50

ss -ant state listening '( sport eq :22 )' #监听且本地端口等于22
ss -ant state fin-wait-1 '( sport = :http or sport = :https )' dst 193.233.7/24 #FIN-WAIT-1状态，源端口为 80 或者 443，目标网络为 193.233.7/24
```
