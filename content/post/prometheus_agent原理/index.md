---
title: "Prometheus Agent 原理"
date: 2025-11-30T23:04:03+08:00
lastmod: 2025-12-06T23:04:03+08:00
draft: false
keywords: []
description: ""
tags: ["prometheus"]
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

Prometheus Agent 模式是一种轻量级的、专门用于指标转发的运行模式。它的核心设计理念是将指标的抓取（Scraping）和转发（Remote Write）与重量级的查询（Querying）和本地长期存储（Block Storage）分离开。
<!--more-->

# Agent 模式处理指标的流程

在 Agent 模式下，一个指标从被抓取到被发送出去的完整流程如下：

1. **抓取 (Scrape)**

    - 和标准模式一样，Agent 使用 scrape 包来抓取目标的 `/metrics` 端点。
    - 解析返回的文本数据，生成带有标签和时间戳的样本。
2. **追加到 Agent 存储 (Append)**
    - 抓取到的样本被传递给 Agent 的存储层（agent.DB）。
    - 和普通模式一样，调用 `appender.Append()` 将样本放入一个内存缓冲区中，也就是 `memSeries`，但这个 `memSeries` 结构体没有 `HeadChunk` 相关的字段，只有最基本的标签集和最后时间戳。

      ```go
      // memSeries is a chunkless version of tsdb.memSeries.
      type memSeries struct {
        sync.Mutex
      
        ref  chunks.HeadSeriesRef
        lset labels.Labels
      
        // Last recorded timestamp. Used by Storage.gc to determine if a series is
        // stale.
        lastTs int64
      }
      
      ```

3. **提交并写入 WAL (Commit & Write to WAL)**
    和普通模式一样，当一个抓取批次完成后，调用 `appender.Commit()`。不同的是，Agent 模式下的 `Commit()` 实现只负责将样本数据写入 WAL，而不进行任何块压缩或索引更新。

    ```go
    // Commit submits the collected samples and purges the batch.
    func (a *appender) Commit() error {
      if err := a.log(); err != nil {
        return err
      }
    
      a.clearData()
      a.appenderPool.Put(a)
    
      if a.writeNotified != nil {
        a.writeNotified.Notify()
      }
      return nil
    }
    ```

4. **WAL 监视 (WAL Watcher)**
    - `remote_write` 的核心组件 `QueueManager` 在启动时会创建一个 `wlog.Watcher`。
    - 这个 `Watcher` 持续监视 WAL 目录。当步骤 3 中有新数据写入 WAL 时，`Watcher` 会被唤醒。
5. **读取 WAL 并发送 (Read WAL & Remote Write)**
    - `Watcher` 从 WAL 文件中读取刚刚写入的数据记录。
    - 它将解码后的样本数据传递给 `QueueManager`。
    - `QueueManager` 负责对数据进行分片、批处理，然后通过 HTTP 客户端将其序列化为 Protobuf 格式，并发送到配置的 `remote_write` URL。
6. **WAL 截断 (Truncate)**
    - 一旦 `QueueManager` 确认数据已成功发送到所有远端端点，它会更新一个检查点，告诉 Agent 的存储（agent.DB）这部分 WAL 数据可以被安全地移除了。
    - agent.DB 会定期运行 `truncate` 任务，删除那些已经被所有 `remote_write` 消费者成功处理过的旧 WAL 段文件，从而回收磁盘空间。这个逻辑在 `tsdb/agent/db.go` 的 `truncate` 函数中体现。

# Agent 模式的特点

- 没有 PromQL 执行能力，也不能执行告警规则。

  ```go
  // cmd/prometheus/main.go

  if !agentMode {
      // ... 初始化 Query Engine ...
      queryEngine = promql.NewEngine(opts)

      // ... 初始化 Rule Manager ...
      ruleManager = rules.NewManager(&rules.ManagerOptions{...})
  }
  ```

- 启动一个简化版的 TSDB，只保留 WAL 日志部分，没有 HeadChunk 和 Block。

  ```go
  // cmd/prometheus/main.go

  if !agentMode {
      // 普通模式：初始化完整的 TSDB
      // 会创建 Head 块、压缩数据块、管理 Retention 等
      db, err := openDBWithMetrics(localStoragePath, ...)
      localStorage.Set(db, startTimeMargin)
  }

  if agentMode {
      // Agent 模式：初始化 WAL-only 存储
      // 仅包含 WAL 日志，没有压缩块
      db, err := agent.Open(..., remoteStorage, localStoragePath, &opts)
      localStorage.Set(db, 0)
  }
  ```

- 清理逻辑变化：只要指标通过 Remote Write 成功发送出去，就会从 WAL 中删除对应数据。

  ```go
  // tsdb/agent/db.go
  func (db *DB) run() {
      // ...
      // 获取远端存储已发送的最小时间戳
      ts := max(db.rs.LowestSentTimestamp()-db.opts.MinWALTime, 0)
      // 截断 WAL，删除已发送的数据
      if err := db.truncate(ts); err != nil { ... }
      // ...
  }
  ```

# 总结

Agent 模式本质上是一个**“带缓冲的转发器”。它利用 Prometheus 强大的 Service Discovery 和 Scraping 能力采集数据，写入本地 WAL 作为缓冲（以应对网络中断），然后通过 Remote Write 协议将数据推送到中心化的存储，一旦推送成功，本地数据即被丢弃。这使得它非常适合部署在边缘节点或 Kubernetes 集群中作为 Sidecar。
