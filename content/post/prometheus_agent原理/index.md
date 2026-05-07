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
    
    - agent.DB 每隔 2h（`DefaultTruncateFrequency`）运行 `truncate` 任务，删除那些已经被所有 `remote_write` 消费者成功处理过的旧 WAL 段文件，回收磁盘空间。值得注意的是如果因为接收端长期无法接受数据，为了防止 wal 文件无限累计，有一个拖底的参数 `DefaultMaxWALTime`，最多保留 4h 的 wal 数据。
    
      ```go
      // Default values for options.
      var (
      	DefaultTruncateFrequency = 2 * time.Hour
      	DefaultMinWALTime        = int64(5 * time.Minute / time.Millisecond)
      	DefaultMaxWALTime        = int64(4 * time.Hour / time.Millisecond)
      )
      
      func (db *DB) run() {
      	defer close(db.donec)
      
      Loop:
      	for {
      		select {
      		case <-db.stopc:
      			break Loop
      		case <-time.After(db.opts.TruncateFrequency):
      			ts := max(db.rs.LowestSentTimestamp()-db.opts.MinWALTime, 0)
      
            // 如果最后发送时间太久，ts < maxTS，则按最大wal 保留时间截断
      			if maxTS := timestamp.FromTime(time.Now()) - db.opts.MaxWALTime; ts < maxTS {
      				ts = maxTS
      			}
      
      			db.logger.Debug("truncating the WAL", "ts", ts)
      			if err := db.truncate(ts); err != nil {
      				db.logger.Warn("failed to truncate WAL", "err", err)
      			}
      		}
      	}
      }
      ```
    
      

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



# 内存占用分析

从源码分析，agent 模式因为不启动 head block，没有索引和 headChunk，这部分内存可以省下。剩下的内存占用主要是两部分：

1. scrape 指标接口时，多次 Append 到最后 Commit（WAL 落盘）之间对 series 的临时缓存。
2. 发送 remote write 的 queue 缓存。

首先是第一部分，每次 scrape 指标的 http 接口，parser 会一行行解析文本生成 series，每解析一行（一个series）就会 `Append()` 到两个队列中，一个是 `pendingSamples`，另一个是 `sampleSeries`。整个接口所有指标都解析完成后会调用 `Commit()`，记录 WAL 后清理所有缓存（`pendingSamples`, `sampleSeries`）。

```go
func (a *appender) Append(ref storage.SeriesRef, l labels.Labels, t int64, v float64) (storage.SeriesRef, error) {
	series, err := a.getOrCreate(chunks.HeadSeriesRef(ref), l)
	...

	a.pendingSamples = append(a.pendingSamples, record.RefSample{
		Ref: series.ref,
		T:   t,
		V:   v,
	})
	a.sampleSeries = append(a.sampleSeries, series)

	a.metrics.totalAppendedSamples.WithLabelValues(sampleMetricTypeFloat).Inc()
	return storage.SeriesRef(series.ref), nil
}

func (a *appenderBase) commit() error {
	if err := a.log(); err != nil { // 记录 WAL
		return err
	}

	a.clearData() // 清除 append 的所有缓存

	if a.writeNotified != nil {
		a.writeNotified.Notify()
	}
	return nil
}
```

另一部分是发送端，watcher 监听 WAL 变化，把新的 series 加入 `shards.queues []*queue`。

```
      |-->  queue (shard_1)   --> remote endpoint
WAL --|-->  queue (shard_...) --> remote endpoint
      |-->  queue (shard_n)   --> remote endpoint
```

```go
func (t *QueueManager) Append(samples []record.RefSample) bool {
	currentTime := time.Now()
outer:
	for _, s := range samples {
		...
		lbls, ok := t.seriesLabels[s.Ref]
		...
		meta := t.seriesMetadata[s.Ref]
		backoff := model.Duration(5 * time.Millisecond)
		for {
			select {
			case <-t.quit:
				return false
			default:
			}
			if t.shards.enqueue(s.Ref, timeSeries{
				seriesLabels:   lbls,
				metadata:       meta,
				startTimestamp: s.ST,
				timestamp:      s.T,
				value:          s.V,
				sType:          tSample,
			}) {
				continue outer
			}
      // sample 发送失败的重试流程
			t.metrics.enqueueRetriesTotal.Inc()
			time.Sleep(time.Duration(backoff))
			backoff *= 2
			// It is reasonable to use t.cfg.MaxBackoff here, as if we have hit
			// the full backoff we are likely waiting for external resources.
			if backoff > t.cfg.MaxBackoff {
				backoff = t.cfg.MaxBackoff
			}
		}
	}
	return true
}

func (s *shards) enqueue(ref chunks.HeadSeriesRef, data timeSeries) bool {
	...
	shard := uint64(ref) % uint64(len(s.queues))
	select {
	case <-s.softShutdown:
		return false
	default:
		appended := s.queues[shard].Append(data)
		if !appended {
			return false
		}
		...
	}
}

func (q *queue) Append(datum timeSeries) bool {
	...
	q.batch = append(q.batch, datum)
	if len(q.batch) == cap(q.batch) {
		select {
		case q.batchQueue <- q.batch:
			q.batch = q.newBatch(cap(q.batch))
			return true
		default:
			// Remove the sample we just appended. It will get retried.
			q.batch = q.batch[:len(q.batch)-1]
			return false
		}
	}
	return true
}

```

默认配置，最多有 50 个 queue，每个 queue 算上正在发送的，最多有 12000 * 50 个 sample 可以同时在内存中，发送的最大 TPS 是 1M samples/s。

```go
DefaultQueueConfig = QueueConfig{
  // With a maximum of 50 shards, assuming an average of 100ms remote write
  // time and 2000 samples per batch, we will be able to push 1M samples/s.
  MaxShards:         50,
  MinShards:         1,
  MaxSamplesPerSend: 2000,

  // Each shard will have a max of 10,000 samples pending in its channel, plus the pending
  // samples that have been enqueued. Theoretically we should only ever have about 12,000 samples
  // per shard pending. At 50 shards that's 600k.
  Capacity:          10000,
  BatchSendDeadline: model.Duration(5 * time.Second),

  // Backoff times for retrying a batch of samples on recoverable errors.
  MinBackoff: model.Duration(30 * time.Millisecond),
  MaxBackoff: model.Duration(5 * time.Second),
}
```

```go
type queue struct {
	batchMtx   sync.Mutex
	batch      []timeSeries // 每个 batch 有 MaxSamplesPerSend（2000） 的容量
	batchQueue chan []timeSeries // 有 Capacity / MaxSamplesPerSend = 5 个 buffer batch

	poolMtx   sync.Mutex
	batchPool [][]timeSeries
}

func (s *shards) start(n int) {
	...
	newQueues := make([]*queue, n) // n=会动态调整，最大是MaxShards=50
	for i := range n {
    // MaxSamplesPerSend=2000，每次发送的最大 sample 数量
    // Capacity=10000，
		newQueues[i] = newQueue(s.qm.cfg.MaxSamplesPerSend, s.qm.cfg.Capacity) 
	}

	s.queues = newQueues
	...
	for i := range n {
		go s.runShard(hardShutdownCtx, i, newQueues[i])
	}
}

// newQueue(s.qm.cfg.MaxSamplesPerSend, s.qm.cfg.Capacity)
func newQueue(batchSize, capacity int) *queue {
	batches := capacity / batchSize // 10000 / 2000
	// Always create an unbuffered channel even if capacity is configured to be
	// less than max_samples_per_send.
	if batches == 0 {
		batches = 1
	}
	return &queue{
		batch:      make([]timeSeries, 0, batchSize), // 2000
		batchQueue: make(chan []timeSeries, batches), // 5
		// batchPool should have capacity for everything in the channel + 1 for
		// the batch being processed.
		batchPool: make([][]timeSeries, 0, batches+1),
	}

```

最极端的情况就是当前所有 target 的所有 series 缓存占用的内存，加上发送所有 queue pending samples 占用的内存。基数很大时，scrape 占用的缓存会占主要部分。


# 总结

Agent 模式本质上是一个**“带缓冲的转发器”。它利用 Prometheus 强大的 Service Discovery 和 Scraping 能力采集数据，写入本地 WAL 作为缓冲（以应对网络中断），然后通过 Remote Write 协议将数据推送到中心化的存储，一旦推送成功，本地数据即被丢弃。这使得它非常适合部署在边缘节点或 Kubernetes 集群中作为 Sidecar。
