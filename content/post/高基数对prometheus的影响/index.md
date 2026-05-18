---
title: "高基数对Prometheus的影响"
date: 2026-05-17T10:07:01+08:00
lastmod: 2026-05-17T10:07:01+08:00
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

众所周知 Prometheus 的性能杀手就是高基数，但是高基数对 Prometheus 具体有哪些影响可能并不清楚。为什么高基数是性能瓶颈？搞清楚这个问题，你就清楚了 Prometheus TSDB 大量底层设计原理。高基数贯穿了性能优化的整条主线，本文来一步步介绍。

<!--more-->

首先什么是高基数？Prometheus 中每个时间序列是一个 Series，每一个 Sereis 包含了唯一的 Key-Value 组合。高基数指的是 Series 数量多，也就是唯一的 Key-Value 组合数量多。容易混淆的是 samples 数量多，一个 Series 可以拥有大量 Samples，只要采集间隔够短，持续时间够长，samples 数量就会大量累计，samples 数量是远多于 Series 数量，为什么没有听说 samples 数量导致 Prometheus 性能瓶颈？这个问题我们先按下不表，介绍完基数的影响后，文章会后会给出解答。

导致高基数的原因往往是某些key不断有一些新生成的value，比如user_id, trans_id等类似流水信息被写入了指标的labelvalue中，这通常是由于指标的label设计不合理导致。本文不会对指标设计做介绍，主要讨论的是为什么高基数对性能影响这么大？会造成有哪些危害？

高基数影响方方面面，首先是写入，memSeries 数量增加，headChunk数量也增加，内存占用增加。写入性能方面，labelset增加 导致stripeSeries 可能会有 hash冲突，并且写锁是互斥锁，影响读，导致严重的锁冲突。由于索引是个嵌套map[key]map[value][]seriesID，value增多导致map扩容，内存占用增加，[]seriesID维护成本也增加，GC压力增加。

查询方面，
索引成本：series增多导致同个label=value匹配的seriesID的列表增加，多个selector条件的[]seriesID做交集计算压力增加。
IO读成本：由于需要查的series增多，大量sample分散在block中不同的的chunk，导致大量随机读。
GC成本：查询需要创建大量SeriesIterator对象，查询完需要销毁，GC压力增加。
Promql计算压力：有些语句需要计算大量sample值，有OOM风险。

## 存储性能

### Head Block

### Compact





## 查询性能
