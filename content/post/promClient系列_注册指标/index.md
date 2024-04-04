---
title: "Prometheus仪表化源码解析：指标如何被注册和采集"
date: 2024-03-24T16:14:34+08:00
lastmod: 2024-03-24T16:14:34+08:00
draft: true
keywords: []
description: ""
tags: []
categories: []
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



解析 Prometheus 官方仪表化库第一篇，聚焦指标的注册和收集。

<!--more-->

# 从一个简单的例子开始

Prometheus是云原生领域的标准监控工具，被许多知名服务采用。官方提供了多种语言的[仪表化库](https://prometheus.io/docs/instrumenting/clientlibs/)，简化应用的仪表化（Instrument）过程。Prometheus 的指标以文本格式呈现，通过 HTTP 协议暴露指标接口，**`Content-Type`** 为 `text/plain`。

本文从一个简单的仪表化例子开始，介绍仪表化的基本步骤，详细解析指标注册和指标收集。

仪表化过程必要步骤如下：

1. 定义指标
2. 注册指标
3. 指标埋点
4. 注册 `http.Handler`

```go
package main

import (
 "log"
 "net/http"

 "github.com/prometheus/client_golang/prometheus"
 "github.com/prometheus/client_golang/prometheus/promhttp"
)

// 1. 定义指标
var (
 cpuTemp = prometheus.NewGauge(prometheus.GaugeOpts{
  Name: "cpu_temperature_celsius",
  Help: "Current temperature of the CPU.",
 })
)

// 2. 注册指标
func init() {
 prometheus.MustRegister(cpuTemp) 
}

func main() {
 cpuTemp.Set(65.3) // 3. 指标埋点
 http.Handle("/metrics", promhttp.Handler()) // 4. 注册http handler
 log.Fatal(http.ListenAndServe(":8000", nil))
}
```

Prometheus 有四种指标类型。上面的例子定义了一个 Gauge 指标，用于表示 CPU 温度。更多指标解析将在后续文章中介绍。定义完指标后，将其注册到仪表库提供的注册器（Register）中，完成仪表化准备。我们需要在适当位置获取CPU温度并提供给指标，最后通过HTTP接口暴露指标。访问`http://localhost:8080/metrics` 输出如下：

```text
# HELP cpu_temperature_celsius Current temperature of the CPU.
# TYPE cpu_temperature_celsius gauge
cpu_temperature_celsius 65.3
# HELP promhttp_metric_handler_requests_in_flight Current number of scrapes being served.
# TYPE promhttp_metric_handler_requests_in_flight gauge
promhttp_metric_handler_requests_in_flight 1
# HELP promhttp_metric_handler_requests_total Total number of scrapes by HTTP status code.
# TYPE promhttp_metric_handler_requests_total counter
promhttp_metric_handler_requests_total{code="200"} 0
promhttp_metric_handler_requests_total{code="500"} 0
promhttp_metric_handler_requests_total{code="503"} 0
```

上述就是仪表化应用的过程，接下来我们解析这一切的背后到底发生了什么。

# 注册指标

注册指标实际上是注册一个指标收集器（Collector），收集器在仪表库作为一个接口存在，`NewGauge` 函数实际上是创建了一个 Gauge 类型指标的一个收集器。涉及的步骤包括创建、注册和暴露接口。对应例子中的代码为：

```mermaid
graph LR
 A[NewGauge] --> B[MustRegister]
 B --> C[promhttp.Handler]
```

对应例子中的代码：

```go
prometheus.MustRegister(cpuTemp)
prometheus.NewGauge(...)
http.Handle("/metrics", promhttp.Handler())
```

对应源码：

```go
func MustRegister(cs ...Collector) {
 DefaultRegisterer.MustRegister(cs...)
}

var (
 defaultRegistry              = NewRegistry()
 DefaultRegisterer Registerer = defaultRegistry
 DefaultGatherer   Gatherer   = defaultRegistry
)

func NewGauge(opts GaugeOpts) Gauge {
 desc := NewDesc(
  BuildFQName(opts.Namespace, opts.Subsystem, opts.Name),
  opts.Help,
  nil,
  opts.ConstLabels,
 )
 result := &gauge{desc: desc, labelPairs: desc.constLabelPairs}
 result.init(result) 
 return result
}


type Gauge interface {
 Metric
 Collector
 ...
}

```

`MustRegister` 调用了默认注册器 `DefaultRegisterer` 的注册函数，这种编码方式在 Go语言中很常见。我们还看到 `NewGauge` 创建了一个 `Gauge`，而 `Gauge` 是一个嵌套了 `Collector` 的接口。

注册器结构题是后续收集指标的核心，其实现了 `Collector`、`Gather` 和 `Registerer` 三个接口，其中最重要的是 `Gatherer` 接口。

```mermaid
classDiagram
  class Registerer{
   <<interface>>
    Register(Collector) error
    MustRegister(...Collector)
    Unregister(Collector) bool
  }
  class Resigtry {
   Register(c Collector) error 
   Unregister(c Collector) bool
   MustRegister(cs ...Collector)
   Gather() ([]*dto.MetricFamily, error)
   Describe(ch chan<- *Desc)
   Collect(ch chan<- Metric)
  }
  class Collector {
   <<interface>>
    Describe(chan<- *Desc)
    Collect(chan<- Metric)
  }
  class Gatherer {
   <<interface>>
  Gather() ([]*dto.MetricFamily, error)
  }
  
 Registerer <|.. Resigtry
 Collector <|.. Resigtry
 Gatherer <|.. Resigtry
```

这里补充一个小知识帮助区分 `Gatherer` 和 `Collector` 接口。英文中 "collect" 和 "gather" 两个单词都有收集的意思，细微的分别在于 "collect" 通常涉及收集一组或同一个集合其中的一部分，而 gather 指从不同的来源汇聚到一起。`Collector` 用于收集一系列具有相同目的指标，如 Prometheus 中的一个指标，可以有不同的标签，但指标名不变。而 `Gatherer` 接口用于汇聚多个不同的 `Collector`，即收集不同名称的指标。举例来说，如果只是收集 `CpuTemp` 单个指标的数据，不管是 `CpuTemp{CPU="cpu1"}` 还是 `CpuTemp{CPU="cpu2"}`，都只能算是 "collect"，所以 `CpuTemp` 应该实现 `Collector` 接口。若需同时收集 `CpuTemp` 和 `MemUsage` 等不同指标数据，则属于 "gather"，需要用实现了 `Gatherer` 接口的 `Registgtry`。

让我们仔细看看 `Registry` 结构体的真容，其最核心的字段是 `collectorsByID`，用于储存注册了的 `Collector`。以下是 `Registry` 结构体的部分代码：

```go
func NewRegistry() *Registry {
 return &Registry{
  collectorsByID:  map[uint64]Collector{},
  descIDs:         map[uint64]struct{}{},
  dimHashesByName: map[string]uint64{},
 }
}

type Registerer interface {
 Register(Collector) error
 MustRegister(...Collector)
 Unregister(Collector) bool
}

type Registry struct {
 mtx                   sync.RWMutex
 collectorsByID        map[uint64]Collector // 已注册的收集器
 descIDs               map[uint64]struct{} // 描述符 ID
 dimHashesByName       map[string]uint64
 uncheckedCollectors   []Collector // 未经检查的收集器
 pedanticChecksEnabled bool // 是否启用详细检查
}
```

# 注册http.Handler

每次访问/metrics时，都会触发一次gather，执行所有collector去收集指标，并进行编码。流程如下：

```mermaid
graph TD
 A[promhttp.Handler] --> B[InstrumentMetricHandler]
 B --> E[HandlerFor]
 B --> C[InstrumentHandlerCounter]
 C --> D[InstrumentHandlerInFlight]
 E --> F[HandlerForTransactional]
 F --> G[reg.Gather]
 G --> H[enc.Encode]
```

最终的 `http.Handler`在 `HandlerForTransactional` 中定义

`InstrumentMetricHandler` 完成两件事：仪表化和生成http.Handler

```go
// promhttp 的入口函数
func Handler() http.Handler {
 return InstrumentMetricHandler(
  prometheus.DefaultRegisterer, HandlerFor(prometheus.DefaultGatherer, HandlerOpts{}),
 )
}
```

```mermaid
graph LR
 A --> B
```

在 `InstrumentMetricHandler` 中定义了两个指标，分别是：

1. `promhttp_metric_handler_requests_total` 已处理的请求总数
2. `promhttp_metric_handler_requests_in_flight`：处理中的请求数

```go
func InstrumentMetricHandler(reg prometheus.Registerer, handler http.Handler) http.Handler {
  
  // 定义并注册两个指标：
 // 1. promhttp_metric_handler_requests_total：处理的请求总数
 cnt := prometheus.NewCounterVec(
  prometheus.CounterOpts{
   Name: "promhttp_metric_handler_requests_total",
   Help: "Total number of scrapes by HTTP status code.",
  },
  []string{"code"},
 )
  ...
 // 2. promhttp_metric_handler_requests_in_flight：处理中的请求数
 gge := prometheus.NewGauge(prometheus.GaugeOpts{
  Name: "promhttp_metric_handler_requests_in_flight",
  Help: "Current number of scrapes being served.",
 })
 ...
 return InstrumentHandlerCounter(..., InstrumentHandlerInFlight(..., handler))
}
```

`InstrumentHandlerCounter` 和 `InstrumentHandlerInFlight` 可以看成是两个仪表化代理，具有相似的函数签名，作用是进行指标的埋点工作。：

```go
func(counter *prometheus.CounterVec, next http.Handler, opts ...Option) http.HandlerFunc
```

```go
// promhttp_metric_handler_requests_total
func InstrumentHandlerCounter(counter *prometheus.CounterVec, next http.Handler, opts ...Option) http.HandlerFunc {
 ...
 return func(w http.ResponseWriter, r *http.Request) {
  next.ServeHTTP(w, r)
  ...
 }
}

// promhttp_metric_handler_requests_in_flight
func InstrumentHandlerInFlight(g prometheus.Gauge, next http.Handler) http.Handler {
 return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
  g.Inc()
  defer g.Dec()
  next.ServeHTTP(w, r)
 })
}

```

最后在 `HandlerForTransactional` 中定义最终的 `http.Handler` `h`，需要注意的是默认 `h` 是没有设置timeout

```go
func HandlerFor(reg prometheus.Gatherer, opts HandlerOpts) http.Handler {
 return HandlerForTransactional(prometheus.ToTransactionalGatherer(reg), opts)
}

func HandlerForTransactional(reg prometheus.TransactionalGatherer, opts HandlerOpts) http.Handler {
 ...  
 // 未设置timeout
 h := http.HandlerFunc(func(rsp http.ResponseWriter, req *http.Request) {
  ... 
    // 收集指标
  mfs, done, err := reg.Gather()
  ... 
  w := io.Writer(rsp)
  ...
    // 编码指标
  enc := expfmt.NewEncoder(w, contentType)
  ...
  for _, mf := range mfs {
   if handleError(enc.Encode(mf)) {
    return
   }
  }
  ...
 })

  // 没有timeout，直接返回h
 if opts.Timeout <= 0 {
  return h
 }
 // 设置timeout
 return http.TimeoutHandler(h, opts.Timeout, fmt.Sprintf(
  "Exceeded configured timeout of %v.\n",
  opts.Timeout,
 ))
}
```

```mermaid

```

```go


```

`collectorID` 是通过将每个描述符的 ID 进行异或操作得到的。这是一种创建唯一标识符的方法。异或操作有以下特性：

1. 任何数和 0 做异或操作，结果仍然是原来的数。
2. 任何数和其自身做异或操作，结果是 0。
3. 异或操作满足交换律和结合律。

因此，无论描述符的 ID 以何种顺序出现，其异或结果（即 `collectorID`）都是一样的。这意味着，只要一个收集器产生的描述符 ID 集合不变，那么计算出的 `collectorID` 就会保持不变，从而可以作为该收集器的唯一标识符。

这种方法的一个优点是，即使在描述符 ID 集合中添加了重复的 ID，`collectorID` 也不会改变，因为任何数和其自身做异或操作的结果是 0。这就是为什么代码中允许在同一个收集器中有重复的描述符，但它们的存在必须是无操作的（no-op）。

```go
a := 5 // 二进制表示：101
b := 3 // 二进制表示：011
c := a ^ b // 二进制表示：110，十进制表示：6
```

异或操作在编程中有许多常见的应用场景：

1. **交换两个变量的值**：异或操作可以用于交换两个变量的值，而无需使用临时变量。例如：

   a ^= b

   b ^= a

   a ^= b

   在这个例子中，`a` 和 `b` 的值会被交换。

2. **检查奇偶性**：异或操作可以用于检查一个数的奇偶性。如果一个数和 1 进行异或操作，结果仍然是原来的数，那么这个数就是偶数；如果结果是原来的数加 1，那么这个数就是奇数。

3. **找出唯一的元素**：如果一个数组中的所有元素都出现了两次，只有一个元素出现了一次，那么可以通过异或操作找出这个元素。因为任何数和其自身做异或操作的结果是 0，所以数组中出现两次的元素在异或操作后会变成 0，只剩下出现一次的元素。

4. **加密和解密**：异或操作也可以用于简单的加密和解密。如果一个字符和一个密钥进行异或操作，就可以得到加密后的字符；如果加密后的字符再和同一个密钥进行异或操作，就可以得到原来的字符。这是因为任何数和其自身做异或操作的结果是 0，所以原来的字符和加密后的字符做异或操作的结果是密钥。

以上就是异或操作在编程中的一些常见应用场景。

```go
func (r *Registry) Register(c Collector) error {
 var (
  descChan           = make(chan *Desc, capDescChan)
  newDescIDs         = map[uint64]struct{}{}
  newDimHashesByName = map[string]uint64{}
  collectorID        uint64 // All desc IDs XOR'd together.
  duplicateDescErr   error
 )

 // 将描述符发送到 descChan 通道
 go func() {
  c.Describe(descChan)
  close(descChan)
 }()

 ... 
 
 for desc := range descChan {
  ...
  if _, exists := newDescIDs[desc.id]; !exists {
   // 获取新 descIds 和 collectorID
   newDescIDs[desc.id] = struct{}{}
   collectorID ^= desc.id // collectorID
  }
  ...
  // 获取新 DimHashes
  newDimHashesByName[desc.fqName] = desc.dimHash
  ...
 }

 ... 

 // 将新 descIds、collectorID、DimHashes 存储 register
 r.collectorsByID[collectorID] = c
 for hash := range newDescIDs {
  r.descIDs[hash] = struct{}{}
 }
 for name, dimHash := range newDimHashesByName {
  r.dimHashesByName[name] = dimHash
 }
 return nil
}
```

借鉴意义：

1. channel赋值nil跳过case
2. 合适的时机增加goroutine‘
3. close channel 后，为了防止内存泄漏，需要defer 把 channel 排空

将已关闭的通道设置为﻿nil可以从﻿select语句中移除这个分支，因为对﻿nil通道的操作会被永久阻塞。这降低了每次﻿select调用的开销，提高了效率。

```go
cmc := checkedMetricChan

umc := uncheckedMetricChan

...

case metric, ok := <-cmc:

  if !ok {

​    cmc = nil

​    break

  }

...

case metric, ok := <-umc:

  if !ok {

​    umc = nil

​    break

  }
```

**5.** **清晰的资源管理和退出策略**

​ • 使用﻿defer语句来确保资源被适当清理，无论函数是正常结束还是提前返回。

​ • 使用﻿nil来标记已关闭的channel，避免在﻿select中重复选择已关闭的channel。

```go
defer func() {

  for range checkedMetricChan {}

  for range uncheckedMetricChan {}

}()
```

使用﻿MultiError类型来收集并处理多个goroutine产生的错误。

```go
errs.Append(processMetric(/*...*/))
```

根据待处理的收集器数量动态调整goroutine的数量，可以有效利用资源，避免创建过多的goroutine导致的资源浪费或竞争。

```go
goroutineBudget := len(r.collectorsByID) + len(r.uncheckedCollectors)

...

go collectWorker()

goroutineBudget--

...

go func() {

  wg.Wait()

  close(checkedMetricChan)

  close(uncheckedMetricChan)

}()
```

```mermaid
graph LR
 A[collectWorker] -->|checkedMetricChan| B[case metric, ok := <-cmc:]
 A -->|uncheckedMetricChan| C[case metric, ok := <-umc]
```

```go
func (r *Registry) Gather() ([]*dto.MetricFamily, error) {

 ...
 // 初始化完成 gather 所需的数据结构
 var (
  checkedMetricChan   = make(chan Metric, capMetricChan)
  uncheckedMetricChan = make(chan Metric, capMetricChan)
  metricHashes        = map[uint64]struct{}{}
  wg                  sync.WaitGroup
  errs                MultiError    
  registeredDescIDs   map[uint64]struct{}
 )
 goroutineBudget := len(r.collectorsByID) + len(r.uncheckedCollectors)
 metricFamiliesByName := make(map[string]*dto.MetricFamily, len(r.dimHashesByName))
 checkedCollectors := make(chan Collector, len(r.collectorsByID))
 uncheckedCollectors := make(chan Collector, len(r.uncheckedCollectors))
 for _, collector := range r.collectorsByID {
  checkedCollectors <- collector
 }
 for _, collector := range r.uncheckedCollectors {
  uncheckedCollectors <- collector
 }

 // 开始工作
 wg.Add(goroutineBudget)
 // collect 工作为串行
 collectWorker := func() {
  for {
   select {
   case collector := <-checkedCollectors:
    collector.Collect(checkedMetricChan)
   case collector := <-uncheckedCollectors:
    collector.Collect(uncheckedMetricChan)
   default:
    return
   }
   wg.Done()
  }
 }
 go collectWorker()
 goroutineBudget--

 // 释放channel
 go func() {
  wg.Wait()
  close(checkedMetricChan)
  close(uncheckedMetricChan)
 }()
 defer func() {
  if checkedMetricChan != nil {
   for range checkedMetricChan {
   }
  }
  if uncheckedMetricChan != nil {
   for range uncheckedMetricChan {
   }
  }
 }()

  // 在这段代码中，checkedMetricChan 被复制到 cmc 变量是为了在 select 语句中可以将其设置为 nil。在 Go 的 select 语句中，如果一个 case 对应的通道为 nil，那么这个 case 就会被忽略。
 cmc := checkedMetricChan
 umc := uncheckedMetricChan

 for {
  select {
  case metric, ok := <-cmc:
      if !ok {
        cmc = nil
        break
      }
   ... // 对metrics进行检查，确保指标的有效性和一致性。
  case metric, ok := <-umc:
   ...
  default: // collecter 收集指标速度慢，启动更多 goroutine
   // 所有 collector 都已经 collect 完毕，或者 goroutineBudget 用完
   if goroutineBudget <= 0 || len(checkedCollectors)+len(uncheckedCollectors) == 0 {
    select {
    case metric, ok := <-cmc:
     ...
    case metric, ok := <-umc:
     ...
    }
    break
   }

   // 还有 collector 未 collect，启动更多 goroutine 处理
   go collectWorker()
   goroutineBudget--
   runtime.Gosched()
  }
  ...
 }
 return internal.NormalizeMetricFamilies(metricFamiliesByName), errs.MaybeUnwrap()
}
```

# 使用自己定义的Register

根据[前文](#注册指标收集器 Collector)源码解析，有两种方式自定义register：

1. 需要 `promhttp_metric_handler_requests_total` 和 `promhttp_metric_handler_requests_in_flight` 指标

   ```go
   reg := prometheus.NewRegistry()
   promhttp.InstrumentMetricHandler(reg, HandlerFor(reg, HandlerOpts{}))
   ```

2. 不需要仪表化指标

   ```go
   // 创建
   reg := prometheus.NewRegistry()
   // 
   reg.MustRegister(otherCollector())
   http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
   ```

# 参考

[官方仪表化库](https://prometheus.io/docs/instrumenting/clientlibs/)

[Prometheus指标格式](https://prometheus.io/docs/instrumenting/exposition_formats/)
