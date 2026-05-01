---
title: "Prometheus TSDB 内存部分 Head Block 解析"
date: 2026-04-29T15:34:50+08:00
lastmod: 2026-04-29T15:34:50+08:00
draft: true
keywords: []
description: ""
tags: ["prometheus"]
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

Prometheus TSDB 其本质是一个 LSM 树，为了极致的写入性能，采用先写入内存后整理的方式，把随机写转化为顺序写，牺牲了磁盘空间和短期内的读性能。本文介绍 TSDB 内存部分，主要涉及 head block、倒排索引。

<!--more-->

```mermaid
---
config:
  layout: tidy-tree
---
%%{init: {"theme": "base", "themeVariables": {"background": "#ffffff", "primaryColor": "#f8f9fa", "primaryBorderColor": "#333333", "lineColor": "#333333", "fontFamily": "sans-serif"}}}%%
mindmap
    root((TSDB内存部分 HEAD))
        {{"Head block"}}
            [memSereis]
                [metadata]
                    指标名 + 一组唯一标签（Metric Name + Labels）
                [chunks]
                    [sample]
                        ('Timestamp, Value 通常是120个samples或者2小时，会生成一个新的chunk，只有最新的chunk是可写的')
            [symbols table]

        {{"posting index"}}
            


```





Prometheus TSDB 是一个 LSM 树，其内存部分有 `tsdb.Head` 管理，主要包括 `Head block` 和 `Posting index`（倒排索引）组成。



# 内存容量估算
