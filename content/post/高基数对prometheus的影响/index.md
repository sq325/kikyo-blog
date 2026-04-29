---
title: "高基数对Prometheus的影响"
date: 2026-04-29T10:07:01+08:00
lastmod: 2026-04-29T10:07:01+08:00
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

最近在实践中发现有一个prometheus agent实例经常被oom kill，容器设置的memory.limit 为 2GB。agent模式只转发指标，不会提供任何查询与持久化的功能，理论上对内存的需求并不高，但是指标基数过高还是会导致内存占用上升。本文将分析高基数指标对 Prometheus 的影响，其中涉及 TSDB 在内存中的形态，探究 agent 模式内存高的原因。



<!--more-->

```mermaid
---
config:
  layout: tidy-tree
---
%%{init: {"theme": "base", "themeVariables": {"background": "#ffffff", "primaryColor": "#f8f9fa", "primaryBorderColor": "#333333", "lineColor": "#333333", "fontFamily": "sans-serif"}}}%%
mindmap
    root((高基数))
        {{"内存"}}
            ["倒排索引膨胀"]
            ["head chunk保存所有活跃series"]
        {{"查询性能"}}
        {{"compaction oom风险"}}
            "Compaction 处理 1万 × 120个样本 = 120万个数据点"
            ("`  同时需要：
        - 读取所有 series 的 chunks
        - 重建索引（posting lists）
        - 写入新 Block
    内存峰值：原有内存的 2-3 倍`") 
        {{"wal"}}
            "100万 series：重启耗时 ~分钟级"
            


```

# 内存占用

# 查询压力

# 


