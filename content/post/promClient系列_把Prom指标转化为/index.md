---
title: "Prometheus Client系列：如何获取指标值"
date: 2024-06-11T23:42:40+08:00
lastmod: 2024-06-16T23:42:40+08:00
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

最近在工作中有一个需求，需要将 Prometheus 指标以指定格式输出为文本。常规使用 go-client 库开发的指标会以 /metrics 接口暴露，格式是 [Prometheus 指标标准的文本格式](https://prometheus.io/docs/concepts/data_model/)，但如果我想在开发的 Exporter 中以其他格式输出指标，该怎么办呢？其中最主要的困难是如何获取当前指标的值。

# 如何获取指标值

client_golang 中对指标的定义如下：

```go
type Metric interface {
    Desc() *Desc
    Write(*dto.Metric) error
}

type Gauge interface {
	Metric
	Collector

	Set(float64)
	Inc()
	Dec()
	Add(float64)
	Sub(float64)
	SetToCurrentTime()
}

type Counter interface {
	Metric
	Collector

	Inc()
	Add(float64)
}
```

不管是 Counter 还是 Gauge，都没有实现类似 GetValue() 获取当前值的方法。那么如何获取当前指标的值呢？仔细查阅 client_golang 源码，counter 结构体实现了 `get()` 方法。

```go
func (c *counter) get() float64 {...}
```

但是这个方法是私有的，无法直接调用，同时 gauge 没有实现这个方法。那么如何获取当前指标的值呢？
这就要聊几句 ProtoBuf 了。Prometheus 的指标是通过 ProtoBuf 定义的，client_golang 库中的 `Write` 方法就是将指标写入到 ProtoBuf 中。那么我们可以通过 `Write` 方法将指标写入到 ProtoBuf 中，然后再从 ProtoBuf 中获取指标的值。gauge 和 counter 的 Write 方法：

```go
func (g *gauge) Write(out *dto.Metric) error {
	val := math.Float64frombits(atomic.LoadUint64(&g.valBits)) // 获取 gauge 的 value
	return populateMetric(GaugeValue, val, g.labelPairs, nil, out)
}

func (c *counter) Write(out *dto.Metric) error {
	var exemplar *dto.Exemplar
	if e := c.exemplar.Load(); e != nil {
		exemplar = e.(*dto.Exemplar)
	}
	val := c.get() // 获取 counter 的 value

	return populateMetric(CounterValue, val, c.labelPairs, exemplar, out)
}
```

在 Write 方法中果然有把指标值写入到 ProtoBuf 的操作。再看看 `populateMetric` 函数：

```go
func populateMetric(
	t ValueType,
	v float64,
	labelPairs []*dto.LabelPair,
	e *dto.Exemplar,
	m *dto.Metric,
) error {
	m.Label = labelPairs
	switch t {
	case CounterValue:
		m.Counter = &dto.Counter{Value: proto.Float64(v), Exemplar: e}
	case GaugeValue:
		m.Gauge = &dto.Gauge{Value: proto.Float64(v)}
	case UntypedValue:
		m.Untyped = &dto.Untyped{Value: proto.Float64(v)}
	default:
		return fmt.Errorf("encountered unknown type %v", t)
	}
	return nil
}
```

很简单，就是把值写到对应类型的 ProtoBuf 结构中，如 `dto.Counter` 和 `dto.Gauge`。幸运的是这两个结构体都有 `GetValue()` 方法：

```go
func (m *Counter) GetValue() float64 {
	if m != nil && m.Value != nil {
		return *m.Value
	}
	return 0
}

func (m *Gauge) GetValue() float64 {
	if m != nil && m.Value != nil {
		return *m.Value
	}
	return 0
}
```

所以我们只需要新建一个 `dto.Metric`，再通过 Counter 和 Counter 接口类型的的 Write 方法把指标写入到 `dto.Metric` 中，然后再通过 `dto.Metric` 的 `Counter` 和 `Gauge` 字段的 `GetValue()` 方法获取当前指标的值。这样就可以获取到当前指标的值了。`dto.Metric` 包含了 `dto.Gauge` 和 `dto.Counter` ，`populateMetric` 函数会帮我们判断指标类型并给 `dto.Metric` 字段赋值。

这里给出一个例子：

```go
import (
	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

// Metric represents a wrapper for prometheus.Metric
type Metric interface {
	GetVal() float64
}

// implement Metric interface
type gauge struct{ d *dto.Metric }
type counter struct{ d *dto.Metric }

// NewMetric returns a Metric interface based on the type of prometheus.Metric
// Only Gauge and Counter are supported
func NewMetric(m prometheus.Metric) Metric {
	d := &dto.Metric{}
	m.Write(d)

	switch m.(type) {
	case prometheus.Gauge:
		return gauge{d}
	case prometheus.Counter:
		return counter{d}
	default:
		return nil
	}
}

func (g gauge) GetVal() float64 {
	return g.d.GetGauge().GetValue()
}

func (c counter) GetVal() float64 {
	return c.d.GetCounter().GetValue()
}

```

# 如何获取向量类型指标值

解决了单个指标获取值的问题，获取向量指标值的问题就有思路了。向量指标是通过 `prometheus.NewCounterVec` 和 `prometheus.NewGaugeVec` 创建的，这两个方法返回的是 `CounterVec` 和 `GaugeVec` 类型，这两个类型都有 `GetMetricWithLabelValues` 方法，签名如下：

```go
GetMetricWithLabelValues(lvs ...string) (prometheus.Metric, error)
```

可以先通过标签值获取指标，再使用上述获取单个指标值的方法获取当前指标的值。
博主已经把获取单个指标值和向量指标值开源了一个库，[点击这](https://github.com/sq325/promTrigger)查看。

# 参考

[promTrigger](https://github.com/sq325/promTrigger)
[dto](https://github.com/prometheus/client_model/blob/a534ba6f2551174b8a7792843b58beebeda5fbd4/go/metrics.pb.go#L255)
