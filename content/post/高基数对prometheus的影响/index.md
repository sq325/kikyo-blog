---
title: "高基数对Prometheus的影响"
date: 2026-05-17T10:07:01+08:00
lastmod: 2026-05-24T10:07:01+08:00
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

众所周知，Prometheus 的性能杀手就是“高基数（High Cardinality）”。但高基数具体会对 Prometheus 造成哪些深远的影响？为什么它会成为不可逾越的性能瓶颈？搞清楚这个问题，有助于我们更深入地理解 Prometheus TSDB 的大量底层设计原理。高基数其实贯穿了 Prometheus 性能优化的整条主线，本文将带你一步步拆解。

<!--more-->

首先，什么是高基数？在 Prometheus 中，每个时间序列（Time Series）被称为一个 Series，它由唯一的指标名称（Metric Name）和一系列标签（Label Key-Value 组合）唯一确定。**高基数指的就是 Series 数量庞大，即唯一标签组合的数量极多**。

与之容易混淆的另一个概念是“样本数（Samples）多”。一个 Series 在生命周期内会因为不断抓取而产生大量 Samples。只要采集间隔够短、持续时间够长，Samples 的数量就会大量累计，且远超 Series 的数量。但为什么很少听到“Samples 数量导致 Prometheus 性能崩溃”？这个问题我们先按下不表，在剖析完基数的影响后再来解答。

导致高基数的原因，往往是不合理的标签设计——例如将 `user_id`、`transaction_id`、`client_ip` 等具有无限可能的流水变量写入到了 label 中。本文不展开讨论指标设计，主要探讨的是：在出现这种高基数现象后，具体会对 Prometheus 造成哪些致命危害？

## 写入与存储性能

Prometheus 写入指标分为两个主要阶段：第一阶段是将数据快速写入内存中的 Head Block（并记录 Write-Ahead Log）；第二阶段是在合并 Head Block 中多个 chunks 后，生成硬盘中的持久化 Block 结构，这涉及到索引重建、构建符号表、chunks 压缩与落盘。

高基数在这两个阶段都会进行“破坏”，主要体现在内存爆炸、锁竞争、索引维护成本及磁盘空间放大上。

### 内存占用增加与 OOM 风险

在内存 Head Block 中，每一个 Series 背后都对应一个 `memSeries` 结构体，其中包含数据层面的 `headChunk`。大量并发活跃的 Series 意味着海量的 `headChunk`，直接推高内存使用率。更致命的是，`memSeries` 会完整保留 labels 的字面数据（`memSeries.lset`），由于这部分数据无法像 samples 一样使用 XOR 算法进行高效压缩，其内存占用甚至会超过数据块本身。这使得 Prometheus 在高基数下极易触发 OOM (Out of Memory) 被系统杀掉。

### 锁竞争加剧

每当一个新的数据点需要写入时，Prometheus 必须找到该指标对应的 `memSeries`。这一过程通过 `stripeSeries` 实现，其本质是通过哈希分片（分段锁）来降低并发修改的冲突。当海量 Series 涌入时，哈希冲突的概率大幅上升，导致在同一分片锁下的其他读写操作受到阻塞。

锁竞争在 Go 语言中会导致大量 Goroutine 阻塞，引发上下文切换和 CPU 占用飙升。

### 索引维护成本与 GC 压力上升

高基数常常伴随着临时性标签值的频繁变更（如流水号、短暂存活的 Pod 名称）。每次产生新的 Label-Value 组合，倒排索引都需要进行相应的维护。Head Block 中的倒排索引是一个双层嵌套的 Map 结构（`map[string]map[string][]storage.SeriesRef`），每次新建或销毁 Series 都需要更新 Map 和切片结构，导致垃圾回收（GC）压力剧增。

### 拖慢启动速度与 WAL 恢复（补充）

当 Prometheus 崩溃重启时，需要从磁盘回放 WAL (Write-Ahead Log) 来恢复 Head Block 的内存状态。如果发生崩溃前存在高基数问题，WAL 文件中会记录海量的 Series 注册事件。回放这些记录意味着要在短时间内重新分配和构建所有的 `memSeries` 与倒排索引，这不仅会导致启动时间大幅延长（可能长达数十分钟），还有可能在启动阶段直接 OOM。

### 破坏压缩引擎导致空间放大（补充）

TSDB 依靠 Gorilla XOR 算法对连续的样本时间戳和数值进行压缩，有着极高的压缩率。但在高基数场景下，很多 Series 可能是“稀疏”的，即只存活极短时间，包含几个 Sample 就废弃了。这就导致大量 Chunk 无法被填满，压缩算法无法发挥优势，引发严重的**磁盘空间放大**，不仅浪费磁盘，还会加剧 IO 压力。

### Compact 性能受影响

Prometheus 是一个 LSM 树的结构，需要在后台不断进行 Head Block -> level 1 disk block -> level 2 disk block 乃至更高级别块的一系列数据整理（Compact）过程。虽然 Compact 过程通过构造 chunk 迭代器实现了流式的样本数据处理，避免了一次性把所有数据加载到内存，但是 Compact 为了构建 Symbol Table（符号表），依然会把所有的 label value 构建成一个 Map，如果 Block 中包含海量的 label value，这个 Map 仍会占用惊人的内存：

```go
// tsdb/index/index.go : Writer 结构体
type Writer struct {
    symbolCache map[string]uint32 // ！！构建时的高基数内存大户！！
    labelNames  map[string]uint64
    // ...
}
```

此外，在倒排索引构建阶段虽然也是按 `labelName` 批次加载，但如果某个 `labelName`（如 `user_id`）对应了极多的 Series，同样会出现内存用量突增的情况。

## 查询性能

查询过程主要分为三个阶段：1. PromQL 语句解析；2. 获取数据；3. 函数计算。

高基数对查询的影响同样体现在方方面面，除了 PromQL 解析以外，获取数据和函数计算的性能压力都会显著上升。

### 数据获取涉及大量随机读

因为 Series 数量多且存活周期碎片化，涉及的 Chunks 在磁盘上的物理分布通常是不连续的。读取时无法有效利用系统的 Page Cache，会造成大量的**随机读取 (Random I/O)**，严重拖慢读取性能。

### 倒排索引交集与计算量陡增

基数高意味着某些 `labelName` 对应的 Series 数量多，查索引时会导致 PromQL 返回海量的 SeriesID。在查询包含多重条件时，这些庞大的 SeriesID 列表做交集（Intersect）运算的成本极其高昂。

另外，像 `rate(http_requests_total{label=value, ...}[5m])` 这样的语句，函数需要对底层命中的每一条 Series 都进行独立的计算，基数越高，所需的 CPU 计算量就越大。

### 迭代器对象导致 GC 灾难

在查询时，读取每个 Series 的数据前都会创建一个对应的查询迭代器 `SeriesIterator`。高基数不仅意味着需要瞬间分配出百万级的 `SeriesIterator` 对象，在查询结束后又需要迅速回收它们，进而对系统 GC 造成毁灭性的停顿压力。

## 总结

高基数是一把能从各个维度击穿 Prometheus 性能防线的利器。它不仅直接推高了 **内存占用（OOM 风险）**，加剧了 **写入锁竞争**，还会降低 **存储压缩比** 、拖慢 **重启恢复过程**，并让后续的 **倒排索引匹配**、**磁盘 IO** 以及 **聚合计算** 变得异常沉重。

现在回答文章开头的那个问题：为什么 **样本数（Samples）多** 的影响远小于 **Series 多（高基数）**？
主要原因就是：属于同一个 Series 的样本是追加写入同一个 Chunk 的，利用 XOR 算法有着惊人的压缩率；且无论是写入还是查询，同一 Chunk 的内部载体都是连续排布的，顺序 I/O 性能远高于随机 I/O。更关键的是，新增的 Samples 只是往已有的数据结构中追加，并不会产生新建 Series 时的内存对象分配与倒排索引维护成本。因此，只有控制好指标的基数，Prometheus 才能保持高效稳定的运转。
