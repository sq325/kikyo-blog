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

众所周知 Prometheus 的性能杀手就是高基数，但是高基数对 Prometheus 具体有哪些影响？为什么高基数是性能瓶颈？搞清楚这个问题，你就清楚了 Prometheus TSDB 大量底层设计原理。高基数贯穿了性能优化的整条主线，本文将一步步介绍。

<!--more-->

首先什么是高基数？Prometheus 中每个时间序列是一个 Series，每一个 Sereis 包含了唯一的 Key-Value 组合。高基数指的是 Series 数量多，也就是唯一的 Key-Value 组合数量多。容易混淆的是 samples 数量多，一个 Series 可以拥有大量 Samples，只要采集间隔够短，持续时间够长，samples 数量就会大量累计，samples 数量远多于 Series 数量，为什么没有听说 samples 数量导致 Prometheus 性能瓶颈？这个问题我们先按下不表，介绍完基数的影响后再解答这个问题。

导致高基数的原因往往是某些 key 不断有一些新生成的value，比如user_id, trans_id等类似流水信息被写入了指标的labelvalue中，这通常是由于指标的label设计不合理导致。本文不会对指标设计做介绍，主要讨论的是为什么高基数对性能影响这么大？会造成有哪些危害？

## 写入性能

Prometheus 写入指标主要分为两个阶段，第一阶段是通过内存中的 Head Block 快速写入数据，第二阶段是合并 Head Block 中多个 chunks，生成硬盘中的 Block 结构，涉及到索引重建，构建符号表，chunks 压缩与落盘。

高基数对写入性能的影响体现在方方面面，从 Head Block 的内存占用高、锁竞争和索引维护成本上升，到合并整理阶段的符号表与倒排索引构建成本增加。

### 内存占用增加

每一个 Series 背后都是一个 memSeries struct，其中存储数据是内存中的 headChunk 结构。Series 数量和 headChunk 数量可以认为是一一对应的，大量 headChunk 导致内存占用提升。更致命的是 memSeries 会完整保留 labels 数据（`memSeries.lset`），这部分数据因为没有 samples xor 压缩所以占用空间会比 headChunk 多。

### 锁竞争

每当一个指标需要写入，Prometheus 需要找到这个指标对应的 memSeries，通过 stripeSeries 实现，其本质是通过 hash 取模来分配锁，大量的 Series 意味着 hash 冲突的发生概率大幅上升，会堵塞同一个锁下其它所有的读写操作。

锁竞争在 GO 语言中会导致大量 Goroutine 堵塞，CPU 占用增高。

### 索引维护成本上升

高基数常常伴随着一些临时性的 value 值，如流水号，pod 名称等，每次增加一个新的 label-value，倒排索引都需要相应的维护。Head Block 中的倒排索引是一个双层嵌套的 map 结构（`map[string]map[string][]storage.SeriesRef`），每次有新 series 创建或者旧 series 销毁都需要更新 map 和数组，导致 GC 压力上升。

### Compact 性能受影响

Prometheus 是一个 LSM 树的结构，需要在后台不断进行 Head Block -> level 1 disk block -> level 2 disk block -> level 3 diskblock 一系列的整理（compact）过程。虽然 compact 过程通过构造 chunk 迭代器实现流式的处理 sample 数据，不会一次性把所有数据都加载到内存中进行处理，但是 compact 为了构建 symbol tabel（符号表），会把所有 label value 构建成一个 map，如果 block 中包含大量 label value，会导致这个 map 占用大量内存：

```go
// tsdb/index/index.go : Writer 结构体
type Writer struct {
    symbolCache map[string]uint32 // ！！内存大户！！
    labelNames  map[string]uint64
    // ...
}
```

另一个高基数对 compact 的影响在索引构建阶段，虽然 Prometheus 不会一次性加载所有 label 到内存进行索引构建，而是按 labelName 一批一批加载并构建对应倒排索引。风险是若果某个 label name 对应了太多的 series，比如高基数情况下的 job_name, instance, user_id 等，会出现内存突增的情况。

## 查询性能

查询主要分为三个阶段：1. PromQL 语句解析。2. 获取数据。 3. 函数计算。

高基数对查询的影响同样体现在方方面面，出了 PromQL 解析以外，获取数据和函数计算的性能压力都显著上升。

### 获取数据涉及大量随机读

因为 Series 数量多，设计的 chunks 都是不连续分布的，读取时会造成大量随机 IO，影响读取性能。



### samples 数量多导致计算量陡增

基数多意味着某些 label name 对应的 series 数量多，索引阶段会导致一个 PromQL 返回大量 SeriesID，多个条件情况下 SeriesID列表做交集运算成本增加。

诸如 `rate(http_request_total{label=value, ...}[5m])` 这样的语句，rate 函数需要对每个 series 都进行独立计算，基数高导致计算量增加。



### 迭代器对象 GC 压力增加

查询时，读取每个 Series 数据前会创建一个对应的迭代器 `SeriesIterator`，高基数意味着需要创建大量 `SeriesIterator` 对象，在查询完成后有需要回收这些对象，对 GC 造成压力。

## 总结

本文对高基数造成的影响做了一一介绍，从指标的摄入和查询两个方向展开，对写入和查询都造成严重影响，对写入最直接的影响时内存压力和锁竞争，直接影响写入性能。对查询会导致随机大量随机 IO和函数计算量增加，也直接影响查询性能。

现在回答文章开头的那个问题，为什么 samples 数量多影响远小于指标基数多。主要原因就是 sample 本身通过 xor 压缩，内存占用很小，而且无论是写入还是查询，只要是同一个 series 的 samples，其载体 chunks 内部都是连续排布的，顺序 IO 比随机 IO 性能高非常多，对写入和查询影响都很小，且新增 samples 没有索引维护成本。
