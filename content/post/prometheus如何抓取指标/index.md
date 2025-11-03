---
title: "prometheus如何抓取指标"
date: 2025-11-02T22:33:33+08:00
lastmod: 2025-11-02T22:33:33+08:00
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
## 摄取指标

### scrape指标存储

- scrape metrics → Head chunk（内存） —> Head chunk（mmap） —> block 过程解析
    - scrape metrics → head chunk（memSeries）
        1. **指标抓取 (Scrape Metrics)**
            
            `scrape/scrape.go`
            
            - **过程**: Prometheus 的抓取循环 (`scrapeLoop`) 会定期请求配置的 target (目标) 的 `/metrics` 端点。它解析返回的文本格式（如 OpenMetrics 或 Prometheus Text Format），将每一行解析成一个带有一组标签 (Labels) 和一个样本 (Sample，包含时间戳和值) 的指标。
            - **输出**: 抓取到的样本数据被传递给存储层进行写入。
        2. **写入 Head Block 的内存块 (Append to head chunk in `memSeries`)**
            - **执行者**: head.go 中的 `Appender`。
            - **过程**:
                1. 当 `scrapeLoop` 完成对一个 target 的单次指标抓取后，它已经调用了多次 `app.Append()` 将所有解析出的样本放入了 `Appender` 的内存缓冲区。
                2. 在所有样本都追加完毕后，`scrapeLoop` 会调用一次 app.Commit() 来提交整个抓取批次。
                    
                    ```go
                    // filepath: /Users/sunquan/Documents/GoDemos/prometheus/scrape/scrape.go
                    // ...existing code...
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
                    ```
                    
                3. `Head` 使用 `getOrCreate` 方法，通过标签的哈希值找到或创建一个对应的 `memSeries` 实例。`memSeries` 是单个时间序列在内存中的完整表示。
                4. 样本被追加到 `memSeries` 的当前活动块中。这个块是一个纯内存结构，在代码中是 `memChunk` 类型，它被设计为可写的。
                5. 当一个 `memChunk` 满了（例如，达到120个样本或2小时的时间跨度）或者需要被持久化时，它会被标记为“完成”，并创建一个新的 `memChunk` 来接收后续的样本。
    - Head chunk → mmaped chunk
        - **执行者**: `Head.mmapHeadChunks()` 和 `memSeries.mmapChunks()`。
        - **过程**:
            1. 一个后台进程会定期调用 `mmapHeadChunks()`。
            2. 这个函数会遍历所有的 `memSeries`，并调用每个 series 的 `mmapChunks()` 方法。
            3. `mmapChunks()` 将所有已完成但尚未 m-map 的 `memChunk` 写入到 `chunks_head` 目录下的文件中。
            4. 写入后，这些 `memChunk` 从 `memSeries` 的 `headChunks` 链表中移除，并作为 `mmappedChunk` 的元数据被添加到 mmappedChunks 切片中。
            5. `mmappedChunk` 是一个只读的、由操作系统内核按需从磁盘加载到内存的块。这大大减少了 Prometheus 的常驻内存占用。
        
        ---
        
        一个时间序列（`memSeries`）中的数据块（chunks）存在两种状态：
        
        `func (*a* *headAppender) Commit() (*err* error)`
        
        1. **Head Chunks**: 存在于 Go 的堆内存中，是一个 `memChunk` 类型的链表。其中，只有链表头部的第一个 chunk 是**可写的**，用于接收最新的样本点。链表中的其他 chunk 都是**只读的**，等待被持久化。
        2. **M-mapped Chunks**: 已经被完整写入到磁盘 `chunks_head/` 目录下的文件中，并通过内存映射（mmap）的方式来访问。程序中只保留对这些 chunk 的引用和元数据，其内容由操作系统管理，不再占用 Go 的堆内存。
        
        持久化的核心是 `memSeries.mmapChunks()` 方法。`memSeries` 同时维护着两种 chunk 的引用。
        
        举例：
        
        - **高频场景（例如，scrape_interval = 15s）**:
            - 一个 chunk 需要 120 个样本才能写满。
            - 所需时间 = 120 个样本 * 15 秒/样本 = 1800 秒 = **30 分钟**。
            - 在这种**特定**的写入频率下，一个 chunk 确实大约需要 30 分钟才会被写满并 mmap。**但这只是一个巧合，而不是一个固定的规则。**
        - **低频场景（例如，scrape_interval = 5m）**:
            - 所需时间 = 120 个样本 * 5 分钟/样本 = 600 分钟 = **10 小时**。
            - 在这种情况下，一个 chunk 会在内存中停留长达 10 个小时才会被 mmap。
        - **极高频场景（例如，每秒写入一次）**:
            - 所需时间 = 120 个样本 * 1 秒/样本 = 120 秒 = **2 分钟**。
            - 在这种情况下，一个 chunk 仅在内存中停留 2 分钟就会被 mmap。
        
        **触发mmap持久化的时机**: 
        
        持久化的过程，本质上就是将“Head Chunks”链表中那些已写满的、只读的 chunk，转化为“M-mapped Chunks”的过程。
        
        持久化（即调用 `mmapChunks`）的触发条件是在样本追加的过程中，当一个 chunk 被写满，需要创建一个新的 chunk 时。当系统为一个时间序列（`memSeries`）切割出一个新的活跃 chunk 后，旧的、刚刚被替换下来的那个 chunk 就会被立即加入 mmap 的处理队列。
        
        1. **追加样本**: `memSeries.append()` 是追加样本的核心方法。
        2. **判断是否需要新 Chunk**: 在 append() 内部，它会检查当前的 `headChunks` 是否已满。一个 chunk "满"的条件通常是：
            - 包含的样本数（每个series的sample数）达到了上限（默认为 120）。
            - 样本的时间戳超出了预设的块时间范围（chunkRange，默认为 2 小时）。
            - 这个“切割”新 chunk 的动作，主要由以下几个条件决定（在 head_append.go 的 `appendPreprocessor` 函数中判断）
                1. **样本数量达到上限**：这是最常见的触发条件。一个 chunk 被设计为容纳大约 120 个样本（由 `Options.SamplesPerChunk` 配置）。当第 121 个样本到来时，系统会发现当前 chunk 已满，于是切割一个新 chunk 来存储这个新样本，而旧的、包含 120 个样本的 chunk 就会被 mmap。
                2. **时间跨度达到预测值**：系统会根据样本的写入速率，预测当前 chunk 应该在哪个时间点（`nextAt`）结束。如果新来的样本时间戳超过了这个预测值，也会触发切割。
                3. **块的字节大小超限**：为了防止内存无限增长，每个 chunk 的压缩后字节大小有一个硬性上限。如果追加一个样本会导致超限，系统会强制切割新块。
                4. **编码格式变化**：如果新来的样本需要一种不同的编码格式（例如，从普通浮点数变为直方图），系统也会切割一个新块。
                
                该函数的主要逻辑围绕着一个核心问题：对于即将到来的时间戳为 `t` 的样本，我们是继续使用当前的 `headChunks`，还是应该结束当前块并创建一个新块？它通过一系列条件来做出这个决定：
                
                1. **首次写入（First Write）**: 如果这个时间序列（`memSeries`）是全新的，没有任何 `headChunks` (`c == nil`)，那么别无选择，必须调用 `cutNewHeadChunk` 来创建它的第一个数据块。
                2. **乱序样本（Out-of-Order Sample）**: 函数会检查新样本的时间戳 `t` 是否小于或等于当前 `headChunk` 的最大时间戳 `c.maxTime`。如果是，这说明这是一个乱序样本。对于顺序写入的 `memSeries` 来说，它不会处理这个样本，而是直接返回，并将 `sampleInOrder` 标记为 `false`，告知调用者这是一个乱序情况（乱序样本有专门的独立处理流程）。
                3. **块大小超限（Chunk Size Limit）**: 为了防止内存中的数据块无限增长，有一个基于字节大小的硬性限制 (`maxBytesPerXORChunk`) 1024B - 19。在追加新样本之前，函数会检查当前块的字节大小。如果超过了阈值，就会强制切割一个新块，以保证每个块的内存占用都在可控范围内。
                4. **编码不匹配（Encoding Mismatch）**: 时间序列数据块可以使用不同的编码方式（`chunkenc.Encoding`），例如普通浮点数和直方图就使用不同的编码。如果新来的样本期望的编码方式与当前 `headChunk` 的编码方式不符，函数也会切割一个新块来存储使用新编码的数据。
                5. **时间跨度或样本数量超限（Time/Sample Limit）**: 这是最精妙的部分。TSDB 不仅关心块的字节大小，还希望数据块在**时间维度**上大致均匀。
                    - `nextAt`: 每个 `memSeries` 都有一个 `nextAt` 字段，它预测了当前 `headChunk` 应该在哪个时间戳结束。如果新样本的时间戳 `t` 超过了 `nextAt`，就意味着该切割新块了。
                    - samplesPerChunk: 还有一个基于样本数量的软限制。如果一个块里的样本数过多（例如，超过了期望值的两倍），这通常意味着数据写入速率突然加快。为了适应这种变化，函数会立即切割一个新块。
                    - **预测性调整**: `nextAt` 的值不是一成不变的。当一个块的样本数达到某个阈值（如 25%）时，函数会调用 `computeChunkEndTime` 来根据当前的写入速率重新预测一个更合适的结束时间。这是一种自适应机制，旨在让数据块在时间上分布得更均匀，这对于后续的查询性能至关重要。
                
                ```go
                func (s *memSeries) appendPreprocessor(t int64, e chunkenc.Encoding, o chunkOpts) (c *memChunk, sampleInOrder, chunkCreated bool) {
                	// We target chunkenc.MaxBytesPerXORChunk as a hard for the size of an XOR chunk. We must determine whether to cut
                	// a new head chunk without knowing the size of the next sample, however, so we assume the next sample will be a
                	// maximally-sized sample (19 bytes).
                	const maxBytesPerXORChunk = chunkenc.MaxBytesPerXORChunk - 19
                
                	c = s.headChunks
                
                	if c == nil {
                		if len(s.mmappedChunks) > 0 && s.mmappedChunks[len(s.mmappedChunks)-1].maxTime >= t {
                			// Out of order sample. Sample timestamp is already in the mmapped chunks, so ignore it.
                			return c, false, false
                		}
                		// There is no head chunk in this series yet, create the first chunk for the sample.
                		c = s.cutNewHeadChunk(t, e, o.chunkRange)
                		chunkCreated = true
                	}
                
                	// Out of order sample.
                	if c.maxTime >= t {
                		return c, false, chunkCreated
                	}
                
                	// Check the chunk size, unless we just created it and if the chunk is too large, cut a new one.
                	if !chunkCreated && len(c.chunk.Bytes()) > maxBytesPerXORChunk {
                		c = s.cutNewHeadChunk(t, e, o.chunkRange)
                		chunkCreated = true
                	}
                
                	if c.chunk.Encoding() != e {
                		// The chunk encoding expected by this append is different than the head chunk's
                		// encoding. So we cut a new chunk with the expected encoding.
                		c = s.cutNewHeadChunk(t, e, o.chunkRange)
                		chunkCreated = true
                	}
                
                	numSamples := c.chunk.NumSamples()
                	if numSamples == 0 {
                		// It could be the new chunk created after reading the chunk snapshot,
                		// hence we fix the minTime of the chunk here.
                		c.minTime = t
                		s.nextAt = rangeForTimestamp(c.minTime, o.chunkRange)
                	}
                
                	// If we reach 25% of a chunk's desired sample count, predict an end time
                	// for this chunk that will try to make samples equally distributed within
                	// the remaining chunks in the current chunk range.
                	// At latest it must happen at the timestamp set when the chunk was cut.
                	if numSamples == o.samplesPerChunk/4 {
                		s.nextAt = computeChunkEndTime(c.minTime, c.maxTime, s.nextAt, 4)
                	}
                	// If numSamples > samplesPerChunk*2 then our previous prediction was invalid,
                	// most likely because samples rate has changed and now they are arriving more frequently.
                	// Since we assume that the rate is higher, we're being conservative and cutting at 2*samplesPerChunk
                	// as we expect more chunks to come.
                	// Note that next chunk will have its nextAt recalculated for the new rate.
                	if t >= s.nextAt || numSamples >= o.samplesPerChunk*2 {
                		c = s.cutNewHeadChunk(t, e, o.chunkRange)
                		chunkCreated = true
                	}
                
                	return c, true, chunkCreated
                }
                ```
                
        3. **切割新 Chunk**: 如果需要新 chunk，会调用 s.cutNewHeadChunk()。这会创建一个新的 `memChunk` 并将其置于 `headChunks` 链表的头部，原来的头部 chunk 就成了链表的第二个元素，状态变为只读。
        
        在 append() 方法的末尾，**在成功切割出一个新的 head chunk 之后**，会调用 s.mmapChunks(a.chunkDiskMapper)。**当一个 `memSeries` 的当前活跃 chunk 被写满，并且系统成功为其创建了一个新的活跃 chunk 后，就会立即触发对旧的、已写满的 chunk 的持久化操作。**
        
        ```go
        func (s *memSeries) append(t int64, f float64, txn uint64, opts chunkOpts) (bool, bool) {
            // ...
            if s.headChunks == nil || s.headChunks.chunk.NumSamples() == 0 {
                // ...
                s.cutNewHeadChunk(t, chunkenc.EncXOR, opts.chunkRange)
                appended = true
            }
            // ...
            if chunkCreated {
                s.mmapChunks(opts.chunkDiskMapper) // <--- 在这里触发
            }
            return appended, chunkCreated
        }
        ```
        
        一个 chunk 在 Go **堆内存**中的生命周期非常短暂。
        
        - 从它被创建（`cutNewHeadChunk`）并开始接收样本，到它被写满，这个过程取决于数据的写入速率。对于一个活跃的时间序列，可能在几分钟到一两个小时内就会写满。
        - **一旦它被写满，并且下一个样本到来导致新的 chunk 被创建，它就会在同一次 append 操作中被 `mmapChunks` 函数处理并写入磁盘。**
        - 写入磁盘并从 `headChunks` 链表解开链接后，它在内存中的生命就结束了，等待下一次 GC 回收。
        
        **持久化步骤**:
        
        1. **调用 `mmapChunks`**: 当满足特定条件时（见下一节），`memSeries.mmapChunks()` 方法被调用。
        2. **遍历只读的 Head Chunks**: 此方法会遍历 s.headChunks 这个链表，但会**跳过第一个（头部）元素**，因为头部 chunk 仍然是活跃的、可写的。
            
            ```go
            // mmapChunks will m-map all but first chunk on s.headChunks list.
            func (s *memSeries) mmapChunks(chunkDiskMapper *chunks.ChunkDiskMapper) (count int) {
                if s.headChunks == nil || s.headChunks.prev == nil {
                    // There is none or only one head chunk, so nothing to m-map here.
                    return
                }
            
                // ... we need to write chunks t0 to t3, but skip s.headChunks.
                for i := s.headChunks.len() - 1; i > 0; i-- {
                    chk := s.headChunks.atOffset(i)
            				chunkRef := chunkDiskMapper.WriteChunk(s.ref, chk.minTime, chk.maxTime, chk.chunk, false, handleChunkWriteError)
            				s.mmappedChunks = append(s.mmappedChunks, &mmappedChunk{
            					ref:        chunkRef,
            					numSamples: uint16(chk.chunk.NumSamples()),
            					minTime:    chk.minTime,
            					maxTime:    chk.maxTime,
            				})
            				count++
                }
                // 将被持久化的 chunk 从 headChunks 链表中移除
            		s.headChunks.prev = nil
            	
            		return count
            }
            ```
            
            1. **写入磁盘**: 对于每一个遍历到的只读 chunk，它会调用 `chunkDiskMapper.WriteChunk()`。这个 `ChunkDiskMapper` 是专门负责将 chunk 写入 `chunks_head/` 目录下的段（segment）文件的服务。写入的磁盘格式在 head_chunks.md 中有详细定义，包含了 series 引用、时间戳、编码方式、数据和 CRC 校验和。
            2. **更新内存状态**:
                - `WriteChunk` 返回一个 chunkRef，这是一个 64 位整数，包含了文件段号和文件内偏移量，是这个 chunk 在磁盘上的唯一标识。
                - 程序创建一个 `mmappedChunk` 结构体，保存这个 chunkRef 和其他元数据（如样本数、时间范围）。
                - 这个新的 `mmappedChunk` 被追加到 s.mmappedChunks 切片中。
            3. **释放内存**: 最关键的一步，将被持久化的 chunk 从 `headChunks` 链表中移除。这样，原先在 Go 堆内存中的 `memChunk` 对象及其包含的样本数据就没有引用了，可以在下一次垃圾回收（GC）时被回收，从而释放内存。
            
    - head&mmaped chunk → block chunk
        
        `Head` 块中的数据（包括所有的 `mmappedChunk`）最终会被压缩成一个独立的、不可变的磁盘块（Block）。
        
        - **执行者**: `tsdb/compactor.go` (虽然未在您的上下文中，但这是标准流程)。
        - **过程**:
            1. 当 `Head` 块的时间范围超过一定阈值（通常是 `block-range` 的 1.5 倍，默认为 2 小时），TSDB 的 `Compactor` 会触发一次 "head compaction"。
            2. `Compactor` 会读取 `Head` 块中一个完整时间窗口（例如 2 小时）内的所有数据（主要来自 `mmappedChunk`）。
            3. 它将这些数据（索引、样本块、Tombstones）写入一个新的、位于磁盘上的块目录中。这个块中的 chunk 就是您所说的 block chunk。
            4. 一旦新的块成功写入，`Head` 就会执行一次垃圾回收（`gc()`）和截断（`Truncate()`），移除已经被压缩到新块中的那部分旧数据（即旧的 `mmappedChunk`）。
        
        ---
        
        当 `Head` 块覆盖的时间范围达到预设的阈值（例如 2 小时）时，后台的 Compaction 任务会被触发。该任务会将 `Head` 块中**所有**的数据（包括内存中的最新数据和已经 mmap 到 `chunks_head` 目录中的旧数据）读取出来，写入一个全新的、以 ULID 命名的标准块目录中。完成后，`Head` 块中被压缩掉的旧数据将被清理
        
        ### 1. 触发条件 (The "When")
        
        `Head` 块的压缩并不是针对单个 m-mapped chunk 的，而是针对整个 `Head` 块的一个时间范围。其主要触发条件是**时间**。
        
        1. **核心判断**：`Head` 块是否“可压缩”（compactable）。这个判断由 head.compactable() 方法执行。
            
            ```go
            // compactable returns whether the head has a compactable range.
            // The head has a compactable range when the head time range is 1.5 times the chunk range.
            // The 0.5 acts as a buffer of the appendable window.
            func (h *Head) compactable() bool {
            	if !h.initialized() {
            		return false
            	}
            
            	return h.MaxTime()-h.MinTime() > h.chunkRange.Load()/2*3
            }
            ```
            
        2. **判断逻辑**：`compactable()` 方法会检查 `Head` 块中最早的时间戳 (h.MinTime()) 和最晚的时间戳 (h.MaxTime())。如果 `MaxTime - MinTime` 的差值超过了 `MinBlockDuration`（通常是 2 小时），并且 `Head` 块中至少有一个完整的 chunk 周期，那么它就返回 `true`。
        3. **后台循环**：`tsdb.DB` 的 `Compact()` 方法 (`db.go`) 是一个后台循环，它会定期运行并检查 h.compactable()。
            
            ```go
            // filepath: /Users/sunquan/Documents/GoDemos/prometheus/tsdb/db.go
            // ...
            func (db *DB) Compact(ctx context.Context) (err error) {
                // ...
                // Check if the head is compactable.
                if !db.head.compactable() {
                    // ...
                    return nil
                }
            
                // ...
                // The head is not being compacted. Let's see if it's time to compact it.
                // We only compact the head if it's past its minimum compact time.
                if db.head.MaxTime()-db.head.MinTime() < db.opts.MinBlockDuration {
                    // ...
                    return nil
                }
            
                return db.compactHead(ctx, rh) // <--- 触发 Head Compaction
            }
            // ...
            ```
            
        
        ### 2. 转换过程 (The "How")
        
        一旦触发，`db.compactHead()` 会启动一个 `Compactor` 来执行实际的转换工作。这个过程可以分解为以下几个步骤：
        
        ### 步骤 1: 创建 Compactor 并准备源数据
        
        `compactHead` 方法会创建一个 `Compactor` 实例。`Compactor` 需要一个 `BlockReader` 作为数据源。在这里，**整个 `Head` 块本身就充当了这个 `BlockReader` 的角色**。
        
        ### 步骤 2: `Compactor` 读取 `Head` 块中的所有数据
        
        `Compactor` 的 `Write()` 方法 (`compact.go`) 会开始执行。它会从作为 `BlockReader` 的 `Head` 块中获取所有的时间序列（Series）和它们对应的所有数据块（Chunks）。
        
        - **关键点**：`Head` 块作为 `BlockReader`，其 `Chunks()` 方法会返回一个迭代器，这个迭代器能够无缝地遍历一个 series 的**所有** chunks，它不区分这个 chunk 是在内存中还是已经 m-map 了。
        - **源码追溯**：当查询或压缩需要某个 chunk 时，会调用 `memSeries.chunk()` 方法 (`head_read.go:439`)。
            - 这个方法会先计算 chunk ID 对应的索引 ix。
            - 如果 ix 在 s.mmappedChunks 切片的范围内，它就会调用 chunkDiskMapper.Chunk(s.mmappedChunks[ix].ref) 从 m-map 文件中读取。
            - 如果 ix 超出了范围，它就会从内存中的 s.headChunks 链表中去查找。
            
            ```go
            // filepath: /Users/sunquan/Documents/GoDemos/prometheus/tsdb/head_read.go
            func (s *memSeries) chunk(id chunks.HeadChunkID, chunkDiskMapper *chunks.ChunkDiskMapper, memChunkPool *sync.Pool) (chunk *memChunk, headChunk, isOpen bool, err error) {
                ix := int(id) - int(s.firstChunkID)
                // ...
                if ix < len(s.mmappedChunks) {
                    // 从 m-map 文件读取
                    chk, err := chunkDiskMapper.Chunk(s.mmappedChunks[ix].ref)
                    // ...
                    return mc, false, false, nil
                }
            
                // 从内存中的 headChunks 链表读取
                ix -= len(s.mmappedChunks)
                offset := headChunksLen - ix - 1
                mc := s.headChunks.atOffset(offset)
                // ...
                return mc, true, isOpen, nil
            }
            ```
            
        
        ### 步骤 3: `BlockWriter` 将数据写入新的持久化块
        
        `Compactor` 内部持有一个 `BlockWriter` (`blockwriter.go`)。`BlockWriter` 负责创建新的块目录（以 ULID 命名），并按照 TSDB 的标准格式写入所有组件：
        
        1. **chunks/ 目录**: `Compactor` 从 `Head` 块读取到的所有 chunks（无论是来自内存还是 mmap 文件）都会被写入到新块目录下的 chunks/ 子目录中。
        2. **`index` 文件**: `Compactor` 会为所有 series 创建新的索引信息（倒排索引、标签等），并写入到 `index` 文件中。
        3. **`meta.json` 文件**: 最后，写入包含块的元数据（如时间范围、series 数量等）的 `meta.json` 文件。
        
        ### 步骤 4: `Head` 块截断 (Truncation)
        
        当 `BlockWriter` 成功写入并关闭了新的持久化块后，`Head` 块需要清理掉已经被压缩的数据，以释放内存和磁盘空间（`chunks_head/` 目录中的文件）。
        
        这个过程由 head.Truncate() 方法完成。它会：
        
        1. 计算出被压缩掉的时间点 mint。
        2. 遍历所有的 `memSeries`。
        3. 对于每个 series，移除所有 maxTime 小于 mint 的 mmappedChunks。
        4. 删除 `chunks_head/` 目录中那些所有 chunk 都已经被截断的旧的段文件。
        5. 更新 `Head` 块的 `MinTime`，使其指向新的、更晚的起始时间。
        
        ### 总结
        
        从 m-mapped head chunk 到持久化 block 的旅程，是整个 `Head` 块生命周期中的一个关键环节。它不是单个 chunk 的迁移，而是**整个 `Head` 块在满足时间条件后，被 `Compactor` 完整地“快照”并转化为一个标准的、只读的磁盘块的过程**。这个过程确保了数据从易失性的内存和临时文件，安全、高效地转变为可供长期查询的持久化格式。
        
    
- 乱序sample如何处理
    
    Prometheus 的主写入路径为了极致的性能，被设计为严格的**顺序追加（Append-Only）**。将一个样本插入到已压缩的 `XORChunk` 中间，需要解压、插入、再压缩，成本极高。为了在不牺牲主路径性能的前提下，又能接收一定程度的“迟到”数据，TSDB 设计了一套完全独立的、专门的乱序样本处理机制。
    
    ### 1. 什么是乱序样本？
    
    一个样本被判定为“乱序”，需要同时满足以下几个条件：
    
    1. **时间戳落后**: 新样本的时间戳 `t_new` **小于或等于** 该时间序列（Series）中已存的最新样本的时间戳 `t_max`。
    2. **不能太旧**: `t_new` 必须**大于或等于** `Head` 块的最小有效时间 `minValidTime`。如果小于这个值，它就是“越界（Out of Bounds）”样本，会被直接拒绝。
    3. **在时间窗口内**: `t_max - t_new` 的差值必须**小于或等于**一个可配置的 `OutOfOrderTimeWindow`（例如 2 小时）。如果超出了这个窗口，也会被拒绝。
    
    ### 2. 为什么需要独立的乱序处理机制？
    
    核心原因是为了**保护主写入路径的性能**。
    
    - **顺序写入的优化**: 主路径使用的 `XORChunk` 格式是为高速顺序追加而设计的。它的压缩算法（Gorilla XOR）依赖于样本之间的差值计算，在末尾追加新样本非常快。
    - **插入的成本**: 在 `XORChunk` 中间插入一个值，意味着需要解压整个块，找到插入点，插入新值，然后重新计算后续所有样本的差值并重新压缩。这个开销是无法接受的。
    
    因此，TSDB 选择“绕道而行”：为乱序样本开辟一个专用的、设计上就允许随机插入的通道。
    
    ### 3. 乱序样本的处理流程（结合源码）
    
    ### 步骤 1：检测 (Detection)
    
    当一个 `Appender` 提交（`Commit`）一批样本时，在 `headAppender.commitSamples` (`head_append.go:1164`) 中，系统会为每个样本调用 `series.appendable()` 来判断其性质。如果该方法返回 `oooSample = true`，则该样本被识别为乱序样本。
    
    ### 步骤 2：存储 (Storage)
    
    被识别为乱序的样本不会进入常规的 `memSeries.append()` 流程，而是被送入一个完全不同的数据结构：`OOOChunk`。
    
    - **数据结构**: `OOOChunk` (`ooo_head.go:22`) 的设计非常直白。它内部只有一个字段：`samples []sample`。这是一个**未压缩的、原始的 `sample` 切片**。
        
        ```go
        // filepath: /Users/sunquan/Documents/GoDemos/prometheus/tsdb/ooo_head.go
        // OOOChunk maintains samples in time-ascending order.
        // ...
        // Samples are stored uncompressed to allow easy sorting.
        type OOOChunk struct {
        	samples []sample
        }
        
        ```
        
    - **插入操作**:
        - 当一个乱序样本需要存入时，会调用 `memSeries.insert()`，它内部会找到或创建这个 series 对应的 `oooHeadChunk`，并调用其 `Insert` 方法。
        - `OOOChunk.Insert()` (`ooo_head.go:38`) 的逻辑是：
            1. 使用二分查找 (`sort.Search`) 在 `samples` 切片中找到正确的时间戳插入位置。
            2. 如果时间戳已存在，则插入失败（返回 `false`），防止重复。
            3. 如果时间戳不存在，则移动切片元素，为新样本腾出空间，并将其插入。
        
        这个过程虽然比顺序追加慢，但因为它操作的是未压缩的切片，所以是可行的，并且完全独立于主路径的 `XORChunk`。
        
    
    ### 步骤 3：持久化 (Persistence)
    
    与常规 `head chunk` 会被 mmap 不同，`OOOChunk` 的持久化策略更简单：
    
    - 当一个 `memSeries` 的 `oooHeadChunk` 中的样本数达到上限（`OutOfOrderCapMax`）时，或者在 `Head` 块进行常规压缩时，这个 `OOOChunk` 会被整体**编码**并**写入**到 `chunks_head/` 目录下的 mmap 文件中。
    - 这个过程由 `memSeries.insert()` 内部逻辑触发，它会调用 `oooHeadChunk.ToEncodedChunks()` 将未压缩的 `sample` 切片转换为标准的、压缩的 `memChunk`，然后写入磁盘。
    
    ### 步骤 4：查询 (Querying)
    
    查询时，TSDB 的 `Querier` 会**同时**从常规数据路径和乱序数据路径中获取数据，然后将两者**合并**，最终呈现给用户一个统一、按时间排序的视图。
    
    - `BlockQuerier` 和 `Head` 块的 `SeriesSet` 实现都会创建一个 `ChainSeriesSet`，它内部包含了来自常规块、`Head` 块以及 OOO 数据的 `SeriesSet`。
    - 在迭代 series 时，它会将来自不同源的同一个 series 的迭代器（Iterator）合并成一个 `populatingChunkSeries`，确保最终输出的样本是全局有序的。
    
    ### 步骤 5：压缩 (Compaction)
    
    乱序数据最终会通过 **Head Compaction** 与主数据流合并。
    
    - 当 `Head` 块被压缩成一个持久化的磁盘块时，`Compactor` 会同时读取 `Head` 块中的常规数据和**所有**乱序数据。
    - 它会将这些数据流合并、去重，然后写入一个新的、干净的、统一的持久化块中。
    - `db_test.go:5155` 中的 `testOOOCompaction` 测试用例就完整地模拟了这个过程：写入常规数据和 OOO 数据，然后触发 Compaction，最后验证新生成的块中包含了两者合并后的完整数据。
    
    ### 总结
    
    乱序样本的处理是一个“旁路系统”：
    
    1. **检测**：在写入时识别出不符合顺序追加条件的样本。
    2. **分流**：将其送入专门的 `OOOChunk` 中。
    3. **独立存储**：`OOOChunk` 使用未压缩的 `sample` 切片，允许高效的中间插入。
    4. **统一查询**：查询引擎负责将主数据流和乱序数据流合并，对用户透明。
    5. **最终合并**：通过 `Head Compaction` 过程，乱序数据最终与主数据合并，回归到统一的持久化块中。
    
    这个设计精妙地平衡了写入性能和数据接收的灵活性，是 Prometheus TSDB 能够稳定处理现实世界中复杂数据源的关键特性之一。
    

### remote receive

处理远程写入（Remote Write）的指标和处理自己抓取（Scrape）的指标，其流程在**入口、数据格式、标签处理和时间戳管理**等方面存在显著区别，但最终都会汇合到**同一个存储追加（Append）核心**。

**远程写入请求处理后 (After a Remote Write Request)**:

- 当 Prometheus 接收到一个 `remote_write` 请求时，它会解析请求中包含的所有时间序列和样本。
- 它会遍历这些数据并多次调用 app.Append()。
- 在处理完整个请求的所有数据后，调用一次 app.Commit() 来提交。
- **代码证据**: 在 `storage/remote/write_handler.go` 的 `write` 函数中，同样使用了 `defer` 来确保 `Commit` 的执行
- 和scrape指标过程对比
    
    **相同点：最终都写入 TSDB Head**
    
    无论是哪种来源的指标，最终都会通过 storage.Appender 接口写入到 TSDB 的 `Head` 块中。这是两条路径的汇合点。
    
    - **Scrape**: 在 `scrape/scrape.go` 的 `scrapeAndReport` 函数中，通过 sl.appender(...) 获取一个 Appender，并在 app.Commit() 时提交。
    - **Remote Write**: 在 `storage/remote/write_handler.go` 的 `write` 或 `writeV2` 方法中，通过 h.appendable.Appender(ctx) 获取一个 Appender，并在 app.Commit() 时提交。
    
    **不同点：从入口到写入前的处理流程**
    
    1. 入口和数据格式
    
    - **Scrape**:
        - **入口**: 由 `scrapeLoop` 主动发起 HTTP GET 请求到目标的 `/metrics` 端点。
        - **数据格式**: 接收的是**纯文本**格式（Prometheus Text Format 或 OpenMetrics）。需要进行词法/语法分析，将文本行解析为标签集（Labels）和样本（Sample）。
    - **Remote Write**:
        - **入口**: 作为一个 HTTP Server，被动地在 `/api/v1/write` 端点接收来自发送端的 HTTP POST 请求。这个逻辑在 `storage/remote/write_handler.go` 的 `ServeHTTP` 方法中。
        - **数据格式**: 接收的是经过 Snappy 压缩的 **Protobuf** 格式 (prompb.WriteRequest 或 `writev2.Request`)。无需解析文本，只需解码 Protobuf 即可得到结构化的时间序列数据。
    
    2. 标签处理 (Label Handling)
    
    - **Scrape**:
        - **会进行丰富的标签重写（Relabeling）**。在指标被存储之前，会应用 `relabel_configs` 和 `metric_relabel_configs` 规则。
        - **会自动附加服务发现和抓取元数据标签**，例如 `job`、`instance`、`__address__` 等。
    - **Remote Write**:
        - **不进行任何标签重写**。它信任发送端提供的标签集，并按原样接收。
        - **只进行标签验证**。如 `write_handler.go` 中的代码所示，它会检查指标名是否存在、标签是否为有效的 UTF-8、是否存在重复的标签名等。如果验证失败，该序列可能会被丢弃。
    
    3. 时间戳管理
    
    - **Scrape**:
        - **主要由 Prometheus 控制时间戳**。默认情况下，一个抓取批次内的所有样本都会被赋予同一个时间戳，即抓取发生的时间。
        - 虽然目标可以暴露带时间戳的样本，但 Prometheus 对其有效性有严格限制。
    - **Remote Write**:
        - **完全依赖发送端提供的时间戳**。这是为了支持联合、长期存储等场景。
        - 因此，Remote Write 路径必须处理**乱序（Out-of-Order）样本**。TSDB 的 `Head` 块有专门的乱序样本处理逻辑（OOO Head Chunk）。
        - 为了防止接收来自未来的数据，`remoteWriteAppender` 会检查样本时间戳是否超过了当前时间的一个小窗口（maxAheadTime，默认为10分钟），如果超过则拒绝。
    
    4. 元数据处理 (Metadata: HELP/TYPE/UNIT)
    
    - **Scrape**:
        - 元数据（`# HELP`, `# TYPE`）和样本在同一个文本流中被解析，并由抓取循环处理。
    - **Remote Write**:
        - **V1 协议 (prompb.WriteRequest)**: 没有直接在时间序列中携带元数据的字段。元数据需要通过一个独立的 `Metadata` 字段发送，与时间序列的关联性较弱。
        - **V2 协议 (`writev2.Request`)**: 这是一个重要改进。如 `write_handler.go` 中的 `appendV2` 函数所示，每个时间序列都可以附带自己的 `Metadata`，接收端会调用 app.UpdateMetadata 将其与序列关联起来。

### record rules

无论是记录规则（Recording Rules）、主动抓取（Scrape）还是被动接收（Remote Receive），它们最终都会汇合到同一个点：**使用 `storage.Appender` 接口将数据提交到 TSDB 的 `Head` 块中**。真正的区别在于数据到达 `Appender` 之前的**来源、处理流程和上下文**。

- 指标生成过程
    
    这是**内部数据循环**。它读取现有数据，计算新数据，然后写回存储。
    
    1. **触发 (Trigger)**:
        - Prometheus 的 `RuleManager` (在 rules 包中) 会根据配置的 `evaluation_interval` 定期启动一轮规则评估。
    2. **查询 (Query)**:
        - 对于每一条记录规则，`RuleManager` 将其 `expr` 字段作为一个 PromQL 查询。
        - 它从自身的存储 (`storage.Storage`) 中获取一个 `Queryable` 接口，并创建一个 `Querier` 来执行这个查询。
        - **这是与另外两种方式最本质的区别：它的数据源是 Prometheus 自己的 TSDB**。
    3. **计算 (Evaluate)**:
        - PromQL 引擎执行查询，对从存储中读取的数据进行计算（如聚合、函数运算等）。
        - 评估的结果是一个新的时间序列向量（`promql.Vector`），其中每个序列都包含新的指标名和标签，以及一个计算出的值。
    4. **追加 (Append)**:
        - `RuleManager` 从存储中获取一个 `storage.Appender` 实例。
        - 它遍历 PromQL 的计算结果。对于每一个新的时间序列，它调用 `appender.Append()`，将新的指标名、标签、评估时间戳和计算出的值添加到 `Appender` 的内存缓冲区中。
    5. **提交 (Commit)**:
        - 在处理完一条规则产生的所有新序列后，`RuleManager` 调用 `appender.Commit()`。
        - 这会将缓冲区中的所有新指标原子性地写入 WAL 并更新到 `Head` 块的内存中，使其对后续的查询和规则评估可见。

## 发出指标

### remote write receiver 指标存储

- 何时触发remote write 到外部receiver
    
    **简而言之:**
    
    - **写入 WAL** 是数据进入本地存储的第一道持久化保障，发生在 `Commit` 期间，是**同步**的。
    - **Remote Write** 是一个**异步**的数据转发过程，它依赖于 WAL 作为数据源，通过 `Watcher` -> `QueueManager` 的管道将数据发送出去，与主摄取流程并行执行。
    
    **Remote Write 是一个独立的后台进程，它通过一个名为 `Watcher` 的组件异步地读取 WAL，并将数据发送到外部端点。**
    
    这个过程与主摄取路径是解耦的，以防止远端存储的延迟或故障影响 Prometheus 本身的指标抓取和本地存储。
    
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

# WAL 原理

- 何时写入 WAL
    
    **简而言之：在 `Appender` 事务提交 (`Commit`) 时，数据被编码并同步写入 WAL 文件。**
    
    这个过程是为了保证数据持久化。即使 Prometheus 进程在数据被完全写入内存或刷写到磁盘块之前崩溃，也可以通过重放 (replay) WAL 来恢复数据。
    
    根据您工作区中的代码，具体流程如下：
    
    1. **获取 Appender**: 当一个抓取 (scrape) 任务完成或一个远程写入请求到达时，它会从 `Head` 获取一个 `Appender` 实例 (`headAppender`)。
    2. **追加数据**: 样本 (`Append`)、Exemplar (`AppendExemplar`) 等数据被追加到 `headAppender` 的内存缓冲区中。此时数据尚未持久化。
    3. **提交事务**: 调用 `appender.Commit()`。这是触发 WAL 写入的关键点。
    4. **写入日志**: 在 `Commit` 方法内部，会调用 `headAppender.log()` 方法。这个方法负责将缓冲区中的所有数据（新序列、样本、Exemplar、元数据等）编码成 record 格式，然后调用 h.head.wal.Log(rec) 将这些记录写入到当前的 WAL 段文件中。
        
        ```go
        func (a *headAppender) Commit() (err error) {
        	if a.closed {
        		return ErrAppenderClosed
        	}
        	defer func() { a.closed = true }()
        
        	if err := a.log(); err != nil {
        		_ = a.Rollback() // Most likely the same error will happen again.
        		return fmt.Errorf("write to WAL: %w", err)
        	}
        	...
        }
        func (a *headAppender) log() error {
            // ... (代码遍历 a.b.series, a.b.samples 等缓冲区)
            // ...
                if len(b.samples) > 0 {
                    rec = enc.Samples(samplesForEncoding(b.samples), buf)
                    buf = rec[:0]
        
                    if err := a.head.wal.Log(rec); err != nil { // <--- 在这里写入 WAL
                        return fmt.Errorf("log samples: %w", err)
                    }
                }
            // ... (对 exemplars, histograms 等执行类似操作)
            return nil
        }
        ```
        
    
    只有当 `log()` 成功返回（即数据已安全写入 WAL），`Commit` 才会继续将数据应用到 `Head` 的内存结构 (`memSeries`) 中。
    
- wal的作用
    
    WAL 的核心原理是**保证数据的持久性和原子性，实现崩溃恢复**。
    
    1. **持久性 (Durability)**: 在将数据写入易失性的内存（`memSeries`）之前，先将其以追加（append-only）的方式写入到磁盘上的日志文件中。这样，即使 Prometheus 进程在数据被刷写到最终的磁盘块（Block）之前崩溃，这些数据也不会丢失。
    2. **原子性 (Atomicity)**: 一次抓取（或一次 API 写入）包含的所有操作（创建新序列、写入多个样本）被视为一个事务。这些操作被一起编码并写入 WAL。只有当所有相关记录都成功写入 WAL 后，这个事务才被认为是成功的，并应用到内存中。如果中途失败，`Rollback()` 会被调用，内存状态不会被污染。
    3. **崩溃恢复 (Crash Recovery)**: 当 Prometheus 重新启动时，它会首先检查并读取 WAL 文件。通过重放（replay）WAL 中记录的所有操作，它可以重建崩溃前 `Head` 块的内存状态，包括所有的时间序列和尚未持久化到磁盘块中的样本。这个过程在 `tsdb/head.go` 的 `Init` 和 `loadWAL` 相关函数中实现。
- Appender
    
    `Commit()` 的作用是**原子性地将 `Appender` 缓冲区中的所有待处理数据应用到数据库中**。它主要完成两件核心事情：
    
    1. **持久化到 WAL (Write-Ahead Log)**:
        - 这是 `Commit` 的首要任务，以保证数据的持久性和崩溃恢复能力。
        - 它会调用内部的 `log()` 方法，将缓冲区中的所有数据（新序列、样本、元数据、Exemplars）编码成二进制记录，然后**同步写入**到磁盘上的 WAL 文件中。
        - **只有当数据安全写入 WAL 后，`Commit` 才会继续执行下一步，**将这些样本应用到 `Head` 的主内存结构中（即更新 `memSeries` 里的 `headChunks`）。如果 WAL 写入失败，整个事务会回滚。
        - **代码证据**: 在您正在查看的 `head_append.go` 文件中：
            
            ```go
            func (a *headAppender) Commit() (err error) {
                // ...
                if err := a.log(); err != nil { // <--- 第一步：写入 WAL
                    _ = a.Rollback() 
                    return fmt.Errorf("write to WAL: %w", err)
                }
                // ...
            }
            ```
            
    2. **更新到内存存储 (Update In-Memory Storage)**:
        - 在成功写入 WAL 之后，`Commit` 会遍历缓冲区中的数据，并将它们正式应用到 `Head` 块的内存结构中（即 `memSeries` 和它的 `headChunks`）。
        - **在此操作完成之前，通过查询是看不到这些新数据的**。`Commit` 使这批数据对查询可见。
        - **代码证据**: 测试文件 `tsdb/db_test.go` 中的 `TestDataAvailableOnlyAfterCommit` 明确验证了这一点：在 app.Commit() 调用之前查询不到数据，调用之后才能查询到。
    
    3. `Commit` 和 `Append` 的区别
    
    `Append` 和 `Commit` 是 storage.Appender 接口定义的两个核心方法，它们代表了事务的两个不同阶段。
    
    | 特性 | `Append` | `Commit` |
    | --- | --- | --- |
    | **粒度** | **单个数据点** (one sample, one exemplar, etc.) | **一批数据** (all data in the appender's buffer) |
    | **执行频率** | 在一个事务中**多次**调用 | 在一个事务中**仅调用一次**（在最后） |
    | **操作对象** | `Appender` 的**内部内存缓冲区** | **WAL 文件** 和 **TSDB Head 的主内存结构** |
    | **持久性** | **不保证持久性**。数据仅在 `Appender` 内存中，进程崩溃即丢失。 | **保证持久性**。通过写入 WAL 实现。 |
    | **可见性** | 追加的数据对外部查询**不可见**。 | 使缓冲区中的所有数据对外部查询**可见**。 |
    | **原子性** | 非原子性操作，只是向缓冲区添加数据。 | **原子性操作**。整批数据要么全部成功，要么全部失败（回滚）。 |
    | **代码位置** | `head_append.go:403` | `head_append.go:1719` |