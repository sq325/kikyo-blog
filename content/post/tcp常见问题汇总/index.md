---
title: "TCP-常见问题汇总"
date: 2021-09-20T22:17:00+08:00
lastmod: 2021-09-20T22:17:00+08:00
draft: false
keywords: []
description: ""
tags: ["tcp", "网络"]
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

使用场景：总结互联网应用会遇到的各种TCP/IP协议、网络报文等问题。

<!--more-->



# 粘包



# RST相关

> 用于异常地关闭连接

RST出现的场景

- 端口不可用：防火墙阻拦或没有监听端口
- socket提前关闭：
  - 本端提前关闭socket但缓冲区还有数据，此时会发送RST给对端
  - 远端提前关闭但本端还在发消息，对端会发送RST

内核收到RST后，应用层只能通过调用读/写操作来感知，此时会对应获得 Connection reset by peer 和Broken pipe 报错。

收到RST包，不一定会断开连接，seq不在合法窗口范围内的数据包会被默默丢弃。

# 幽灵连接



# TIME-WAIT过多



# CLOSE-WAIT过多



