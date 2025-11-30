---
title: "prometheus 指标抓取与存储详解"
date: 2025-11-02T22:33:33+08:00
lastmod: 2025-11-02T22:33:33+08:00
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

<!--more-->

# 指标进入Prometheus TSDB 的途径

Prometheus 可以通过多种方式获取指标数据，总结如下：

```
外部数据源
    ├─ HTTP Scrape
    │   └─> 解析指标 (textparse/protparse)
    │       └─> fanoutAppender (分发)
    │           ├─> dbAppender (本地)
    │           │   └─> initAppender/headAppender (TSDB)
    │           │       └─> getOrCreate (查找/创建 memSeries)
    │           └─> remote.QueueManager (远程)
    │
    ├─ Remote Write
    │   └─> 解析指标 (prompb decode)
    │       └─> fanoutAppender
    │           └─> (同上)
    │
    └─ Recording Rules
        └─> fanoutAppender
            └─> (同上)
```

1. **Pull 模式**：Prometheus 定期从配置的目标（如应用程序、服务等）拉取指标数据。这是 Prometheus 最常用的获取数据的方式。
2. **Push 模式**：外部数据源通过 remote write API 将指标数据推送到 Prometheus。
3. **recording rules**：Prometheus 可以通过定义 recording rules 来生成新的时间序列数据，这些数据也会被存储在 TSDB 中。

无论是哪种方式获取的指标数据，最终都会被存储在 Prometheus 的 TSDB 中，汇合到同一个存储追加（Append）核心。

## Pull 模式指标抓取与存储流程

### 解析指标

**指标格式：**文本 ->|parser| 结构化数据 series (Labels + Sample)

- **过程**: Prometheus 的抓取循环 (`scrapeLoop`) 会定期请求配置的 target (目标) 的 `/metrics` 端点。它解析返回的文本格式（如 OpenMetrics 或 Prometheus Text Format），将每一行解析成一个带有一组标签 (Labels) 和一个样本 (Sample，包含时间戳和值) 的指标。
- **输出**: 抓取到的样本数据被传递给存储层进行写入缓存。

```go
func (sl *scrapeLoop) append(app storage.Appender, b []byte, contentType string, ts time.Time) (total, added, seriesAdded int, err error) {
    // 1. 创建解析器（支持 Prometheus 文本格式、OpenMetrics 等）
    p, err := textparse.New(b, contentType, sl.scrapeClassicHistograms)

    // 2. 包装 appender，添加各种限制
    app = appender(app, sl.sampleLimit, sl.bucketLimit, sl.maxSchema)
    // 这会添加: timeLimitAppender -> limitAppender -> bucketLimitAppender

    // 3. 逐行解析指标
    for {
        et, err := p.Next()

        switch et {
        case textparse.EntryType:
            sl.cache.setType(p.Type())  // 缓存元数据
            continue
        case textparse.EntryHelp:
            sl.cache.setHelp(p.Help())
            continue
        case textparse.EntryHistogram:
            isHistogram = true
        default:
            // 常规样本
        }

        total++

        // 4. 提取指标数据
        if isHistogram {
            met, parsedTimestamp, h, fh = p.Histogram()
        } else {
            met, parsedTimestamp, val = p.Series()
        }
      ....
  
      // 9. 追加样本到 appender（缓存指标）
      if isHistogram {
          ref, err = app.AppendHistogram(ref, lset, t, h, fh)
      } else {
          ref, err = app.Append(ref, lset, t, val)
      }
      ...

```

### 缓存指标

指标格式：memSeries -> headChunk

**过程**: Appender 通过 Append 方法将样本数据传递给存储层。存储层维护一个内存中的时间序列缓存（memSeries），用于高效地追加样本数据。当 scrapeLoop 完成对一个 target 的单次指标抓取后，它已经调用了多次 app.Append() 将所有解析出的样本放入了 Appender 的内存缓冲区。

在整个 scrape 过程最后会调用 `Commit()` 方法将数据提交到 Head 块中。Head 块是 TSDB 的内存部分。同时，`Commit()` 还会写入 WAL 日志以确保数据的持久性。`Commit()` 会遍历 a.samples 切片，对于每个样本，会通过 `series.append` 被追加到当前的 `headChunk` 中。

`Commit()` 只是把指标写入 headChunk 中，指标并未落盘，此时真正落盘的只有 WAL 日志。WAL 日志保证了在指标数据落盘前不会丢失。

```go
func (sl *scrapeLoop) scrapeAndReport(last, appendTime time.Time, errc chan<- error) time.Time {
    // ...
    app := sl.appender(sl.appenderCtx)
    defer func() {
        if err != nil {
            app.Rollback()
            return
        }
        err = app.Commit() // <--- 在抓取和追加完成后触发
        // ...
    }()

    // ... 在循环中多次调用 sl.append，内部会调用 app.Append() ...
    total, added, seriesAdded, appErr = sl.append(app, b, contentType, appendTime)
    // ...
}

// sl.append 会调用 app.Append() 多次将样本追加到内存中的 memSeries 结构中
func (a *headAppender) Append(ref storage.SeriesRef, lset labels.Labels, t int64, v float64) (storage.SeriesRef, error) {
  ...
	s := a.head.series.getByID(chunks.HeadSeriesRef(ref))
  ...
  // 追加到 a.samples 和 a.sampleSeries 切片中。这些缓冲的数据将在 Commit() 方法被调用时真正写入 WAL 和内存块。
	a.samples = append(a.samples, record.RefSample{
		Ref: s.ref,
		T:   t,
		V:   v,
	})
	a.sampleSeries = append(a.sampleSeries, s)
	return storage.SeriesRef(s.ref), nil
}

func (a *headAppender) Commit() (err error) {
  ...
  // 将所有缓冲的数据写入磁盘上的预写日志（WAL）。
  // 只有在 WAL 写入成功后，代码才会继续修改内存中的数据结构。
	if err := a.log(); err != nil {
		_ = a.Rollback() // Most likely the same error will happen again.
		return fmt.Errorf("write to WAL: %w", err)
	}
  ...
	var (
    ...
		series          *memSeries
		appendChunkOpts = chunkOpts{
			chunkDiskMapper: a.head.chunkDiskMapper,
			chunkRange:      a.head.chunkRange.Load(),
			samplesPerChunk: a.head.opts.SamplesPerChunk,
		}
		enc record.Encoder
	)
  ...

		switch {
      ...
		default:
      // 追加到当前的 Head Chunk 中
			ok, chunkCreated = series.append(s.T, s.V, a.appendID, appendChunkOpts)
			if ok {
				if s.T < inOrderMint {
					inOrderMint = s.T
				}
				if s.T > inOrderMaxt {
					inOrderMaxt = s.T
				}
			} else {
				// The sample is an exact duplicate, and should be silently dropped.
				samplesAppended--
			}
		}
    ...
	}

	for i, s := range a.histograms {
		series = a.histogramSeries[i]
		series.Lock()
		ok, chunkCreated := series.appendHistogram(s.T, s.H, a.appendID, appendChunkOpts)
		series.cleanupAppendIDsBelow(a.cleanupAppendIDsBelow)
		series.pendingCommit = false
		series.Unlock()
    ...
	}
  ...
}

```

memSeries 是单个时间序列在内存中的完整表示。样本被追加到 `memSeries` 的当前活动块中。这个块是一个纯内存结构，在代码中是 `memChunk` 类型，它被设计为可写的。当一个 `memChunk` 满了（例如，达到120个样本或2小时的时间跨度）或者需要被持久化时，它会被标记为“完成”，并创建一个新的 `memChunk` 来接收后续的样本。

```go
type memSeries struct {
    // 序列的唯一标识符
    ref  chunks.HeadSeriesRef
    // 序列的标签集
    lset labels.Labels

    // 已持久化到磁盘的 mmap chunks，按时间升序排列
    // 这些 chunks 不可变，等待被压缩进 block
    mmappedChunks []*mmappedChunk
    
    // 内存中正在构建的 head chunks 链表
    // headChunks 指向最新的 chunk，通过 prev 指针链接到更老的 chunk
    headChunks   *memChunk
    
    // 下一次切分 chunk 的时间戳阈值
    nextAt int64

    // 当前 head chunk 的 appender，用于追加新样本
    app chunkenc.Appender
}

type memChunk struct {
	chunk            chunkenc.Chunk
	minTime, maxTime int64
	prev             *memChunk // Link to the previous element on the list.
}
```

### 持久化指标

**指标格式：**`headChunks` -> `M-mapped Chunks`（`chunks_head/`目录下）

在这一步时把内存中 headChunk 数据持久化到磁盘上，并通过mmap机制按需加载到内存中供查询使用。
持久化的过程，本质上就是将“Head Chunks”链表中那些已写满的、只读的 chunk，转化为“M-mapped Chunks”的过程。
需要注意的是 Chunk 的 切割（Cut） 与 持久化（Mmap） 是分离的。在样本追加（Append）过程中，当 Chunk 写满或时间跨度结束时，内存中会立即切割出一个新的 Chunk，旧 Chunk 被推入待处理链表（prev）。对于常规 Chunk，持久化是由后台维护任务周期性触发的，它扫描所有 Series 的待处理链表，调用 mmapChunks 将旧 Chunk 写入磁盘并建立内存映射。

- **执行者**: `Head.mmapHeadChunks()` -> `memSeries.mmapChunks()`。
- **过程**:
    1. 一个后台进程会定期调用 `mmapHeadChunks()`。
    2. 这个函数会遍历所有的 `memSeries`，并调用每个 series 的 `mmapChunks()` 方法。
    3. `mmapChunks()` 将所有已完成但尚未 m-map 的 `memChunk` 写入到 `chunks_head` 目录下的文件中。
    4. 写入后，这些 `memChunk` 从 `memSeries` 的 `headChunks` 链表中移除，并作为 `mmappedChunk` 的元数据被添加到 mmappedChunks 切片中。
    5. `mmappedChunk` 是一个只读的、由操作系统内核按需从磁盘加载到内存的块。这大大减少了 Prometheus 的常驻内存占用。

```go
func (db *DB) run(ctx context.Context) {
    ...
		case <-time.After(1 * time.Minute):
			db.cmtx.Lock()
			if err := db.reloadBlocks(); err != nil {
				level.Error(db.logger).Log("msg", "reloadBlocks", "err", err)
			}
			db.cmtx.Unlock()

			select {
			case db.compactc <- struct{}{}:
			default:
			}
			// 调用 mmapHeadChunks 将内存中的 Head Chunks 持久化到磁盘
			db.head.mmapHeadChunks()
      ...
}
func (h *Head) mmapHeadChunks() {
	var count int
	for i := 0; i < h.series.size; i++ {
		h.series.locks[i].RLock()
		for _, series := range h.series.series[i] {
			series.Lock()
      // 调用 memSeries.mmapChunks 方法将 headChunks 中的 chunk 持久化到磁盘并建立内存映射
			count += series.mmapChunks(h.chunkDiskMapper)
			series.Unlock()
		}
		h.series.locks[i].RUnlock()
	}
	h.metrics.mmapChunksTotal.Add(float64(count))
}

// mmapChunks will m-map all but first chunk on s.headChunks list.
func (s *memSeries) mmapChunks(chunkDiskMapper *chunks.ChunkDiskMapper) (count int) {
  //  s.headChunks 这个链表，但会跳过第一个（头部）元素，因为头部 chunk 仍然是活跃的、可写的
	if s.headChunks == nil || s.headChunks.prev == nil {
		return
	}
	
	for i := s.headChunks.len() - 1; i > 0; i-- {
		chk := s.headChunks.atOffset(i)
    // 写入磁盘
    // ChunkDiskMapper 是专门负责将 chunk 写入 chunks_head/ 目录下的段（segment）文件的服务
		chunkRef := chunkDiskMapper.WriteChunk(s.ref, chk.minTime, chk.maxTime, chk.chunk, false, handleChunkWriteError)
		s.mmappedChunks = append(s.mmappedChunks, &mmappedChunk{
			ref:        chunkRef,
			numSamples: uint16(chk.chunk.NumSamples()),
			minTime:    chk.minTime,
			maxTime:    chk.maxTime,
		})
		count++
	}

	// 将被持久化的 chunk 从 headChunks 链表中移除
	s.headChunks.prev = nil

	return count
}

```

### 疑问

这里有三个问题值得被探讨：

1. 为什么不立即持久化刚切割出来的 chunk？
2. 什么情况下会触发 mmap 持久化？
3. 何时会创建一个新的 chunk？

关于第一个问题：为什么不立即持久化刚切割出来的 chunk？
之所以把切割（Cut）与持久化（Mmap）是分成两个独立的过程，根本原因还是立即持久化刚切割出来的 chunk 会带来如下问题：

1. **性能开销**: 每次切割后立即持久化会导致频繁的磁盘写入操作，增加 I/O 负载，影响整体性能。
2. **内存利用率**: 切割出来的 chunk 可能很快就会被填满，如果立即持久化，可能会导致频繁的读写操作，反而增加了内存和磁盘之间的数据传输。
3. **批量处理**: 通过定期批量持久化，可以更有效地利用磁盘 I/O，减少碎片化，提高写入效率。

关于第二个问题：什么情况下会触发 mmap 持久化？
对于普通的顺序写入数据：

- **频率**: 每 1 分钟。
- **机制**: `DB.run` 循环中的定时器触发 `db.head.mmapHeadChunks()`。
- **行为**: 扫描所有内存序列（Series），将那些已经写满且不再是活跃状态（即链表中除了头部以外）的 Chunk 写入磁盘并进行 mmap。

```go
func (db *DB) Dir() string {
	return db.dir
}

func (db *DB) run(ctx context.Context) {
	defer close(db.donec)

	backoff := time.Duration(0)

	for {
		select {
		case <-db.stopc:
			return
		case <-time.After(backoff):
		}

		select {
		case <-time.After(1 * time.Minute):
			db.cmtx.Lock()
			if err := db.reloadBlocks(); err != nil {
				level.Error(db.logger).Log("msg", "reloadBlocks", "err", err)
			}
			db.cmtx.Unlock()

			select {
			case db.compactc <- struct{}{}:
			default:
			}
			// We attempt mmapping of head chunks regularly.
			db.head.mmapHeadChunks()
		case <-db.compactc:
			db.metrics.compactionsTriggered.Inc()

			db.autoCompactMtx.Lock()
			if db.autoCompact {
				if err := db.Compact(ctx); err != nil {
					level.Error(db.logger).Log("msg", "compaction failed", "err", err)
					backoff = exponential(backoff, 1*time.Second, 1*time.Minute)
				} else {
					backoff = 0
				}
			} else {
				db.metrics.compactionsSkipped.Inc()
			}
			db.autoCompactMtx.Unlock()
		case <-db.stopc:
			return
		}
	}
}
```

另一种情况是数据库关闭时，为了防止数据丢失并加快下次启动速度，在数据库关闭时会强制执行一次持久化。

- **时机**: 调用 `DB.Close()` 时。
- **机制**: `DB.Close()` 内部会调用 `h.mmapHeadChunks()`，确保所有内存中已完成的 Chunk 都被刷新到磁盘上的 `chunks_head` 目录。

// TODO

验证：
可以观察到，一个chunk 满后的1分钟内，Prometheus 的内存就会下降，说明 chunk 被持久化了。

最后一个问题：何时会创建一个新的 chunk？
主要有三种情况会触发新的 chunk 创建：

1. **样本数量达到上限**: 每个 chunk 有一个最大样本数限制（默认是120个样本）。当向当前 chunk 追加样本时，如果发现当前 chunk 已经满了，就会创建一个新的 chunk 来接收后续的样本。
2. **时间跨度结束**: 每个 chunk 也有一个时间跨度限制（默认是2小时）。当追加的样本的时间戳超过了当前 chunk 的时间范围时，也会触发创建一个新的 chunk。
3. **字节大小超过限制**: 当 Chunk（XOR Chunk）占用的字节数超过 maxBytesPerXORChunk (约 1KB) 时。或当 Histogram Chunk 字节数超过 chunkenc.TargetBytesPerHistogramChunk 的 2 倍时。

```go
const (
	MaxBytesPerXORChunk = 1024
	TargetBytesPerHistogramChunk = 1024
	MinSamplesPerHistogramChunk = 10
) 

const maxBytesPerXORChunk = chunkenc.MaxBytesPerXORChunk - 19

func (s *memSeries) histogramsAppendPreprocessor(t int64, e chunkenc.Encoding, o chunkOpts) (c *memChunk, sampleInOrder, chunkCreated bool) {
	...
	if (t >= s.nextAt || numBytes >= targetBytes*2) && (numSamples >= chunkenc.MinSamplesPerHistogramChunk || t >= nextChunkRangeStart) {
		c = s.cutNewHeadChunk(t, e, o.chunkRange)
		chunkCreated = true
	}
	...
}
```

## Remote Write 指标抓取与存储流程

处理远程写入（Remote Write）的指标和处理自己抓取（Scrape）的指标，其流程在入口、数据格式、标签处理和时间戳管理等方面存在显著区别，但最终都会汇合到同一个存储追加（Append）核心。
remote write 会监听 `/api/v1/write` 端点，被动接受经过 Snappy 压缩的 Protobuf 格式 (`prompb.WriteRequest` 或 `writev2.Request`)的指标数据。它会解码这些 Protobuf 数据，将每个时间序列解析成一组标签 (Labels) 和样本 (Sample，包含时间戳和值)。每次请求，在解码这些 Protobuf 数据时都会多次调用 `app.Append()`，在处理完这个请求的所有数据后，调用一次 `app.Commit()` 来提交。
后面的过程和 Pull 模式完全一样，都是通过 Appender 将样本数据传递给存储层，追加到内存中的时间序列缓存（memSeries），最后通过后台任务将内存中的 headChunk 持久化到磁盘上的 chunks_head 目录下。

## Recording Rules 指标抓取与存储流程

recording rules 和前两种指标摄入方式的根本区别在于数据的来源，其是通过 Prometheus 自己的查询接口，查找自己的 TSDB 数据，计算出的结果作为一个新的时序向量（`promql.Vector`）存储到 TSDB 中。

```go
type Vector []Sample
type Sample struct {
	T int64
	F float64
	H *histogram.FloatHistogram

	Metric labels.Labels
}
```

每个 `Sample` 都包含一个时间戳 (T)、一个浮点值 (F) 或一个直方图 (H)，以及一组标签 (Metric)。在计算出这些样本后，Prometheus 会通过 Appender 的 `Append()` 方法将每个样本追加到存储层中，最后调用 `Commit()` 方法提交这些样本。

```go
func (g *Group) Eval(ctx context.Context, ts time.Time) {
	...
	for i, rule := range g.rules {
		...
		func(i int, rule Rule) {
			...
			vector, err := rule.Eval(ctx, ts, g.opts.QueryFunc, g.opts.ExternalURL, g.Limit())
			...

			// Append the resulting samples.
			app := g.opts.Appendable.Appender(ctx)
			seriesReturned := make(map[string]labels.Labels, len(g.seriesInPreviousEval[i]))
      // 每个 rule 处理完成后调用 Commit 提交样本
			defer func() {
				if err := app.Commit(); err != nil {
					...
				}
			}()

			// 遍历结果样本，将其追加到存储中
			for _, s := range vector {
				if s.H != nil {
					_, err = app.AppendHistogram(0, s.Metric, s.T, nil, s.H)
				} else {
					_, err = app.Append(0, s.Metric, s.T, s.F)
				}
				...
			}
			...
		}(i, rule)
	}
	...
}
```

每个 rule 执行完都会调用 `app.Commit()`，将所有追加的样本提交到存储层中，后续的存储过程和前面两种方式完全一样。

# Remote Write 推送指标到其他 Receivers 的过程

前面提到的所有指标摄入方式都会调用 Appender.Commit(), 数据被写入 headChunk 之前会先写入 WAL 日志，Remote Write 转发指标依赖于 WAL 作为数据源，其会监听 WAL 日志的变更，并将新增的样本数据打包成 Protobuf 格式，通过 HTTP POST 请求推送到配置的远程接收端点（Remote Receivers）。这个过程是异步进行的，与指标的摄入过程解耦，以避免影响摄入性能。
具体流程如下：

1. **QueueManager 启动**: Prometheus 启动时，会为每个 `remote_write` 配置创建一个 `QueueManager`。
2. **启动 WAL Watcher**: 每个 `QueueManager` 都会初始化并启动一个 `wlog.Watcher`。这个 `Watcher` 的任务就是 "监视" WAL 目录的变化。
3. **监视和读取 WAL**:
    - 当本地 TSDB 通过 `headAppender` 向 WAL 写入新数据时，它会通过 `WriteNotified` 接口通知 `Watcher` 有新数据可用。
    - `Watcher` 在其 `loop()` 中被唤醒，然后读取新的 WAL 记录。
4. **发送数据**:
    - `Watcher` 将从 WAL 中解码出的样本、Exemplar 等数据，通过 `WriteTo` 接口传递给 `QueueManager`（`QueueManager` 实现了这个接口）。
    - `QueueManager` 将接收到的数据放入内部队列中进行分片和批处理。
    - 最后，`QueueManager` 通过一个 HTTP 客户端将 protobuf 格式的 `WriteRequest` 发送到配置的远端 URL。
