---
title: "[Demo] Go并发编程"
date: 2022-01-28T10:33:33+08:00
lastmod: 2022-01-28T10:33:33+08:00
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

<!--more-->



# 主子协程模式



使用`sync.WaitGroup`在主协程中等待所有子协程执行完成

- `Add`：`WaitGroup` 类型有一个计数器，默认值是0，我们可以通过 `Add` 方法来增加这个计数器的值，通常我们可以通过个方法来标记需要等待的子协程数量；
- `Done`：当某个子协程执行完毕后，可以通过 `Done` 方法标记已完成，该方法会将所属 `WaitGroup` 类型实例计数器值减一，通常可以通过 `defer` 语句来调用它；
- `Wait`：`Wait` 方法的作用是阻塞当前协程，直到对应 `WaitGroup` 类型实例的计数器值归零，如果在该方法被调用的时候，对应计数器的值已经是 0，那么它将不会做任何事情。

```go
package main

import (
    "fmt"
    "sync"
)

func add_num(a, b int, deferFunc func()) {
    defer func() {
        deferFunc()
    }()
    c := a + b
    fmt.Printf("%d + %d = %d\n", a, b, c)
}

func main() {
    var wg sync.WaitGroup
    wg.Add(10)
    for i := 0; i < 10; i++ {
        go add_num(i, 1, wg.Done)
    }
    wg.Wait()
}
```





# 并行编程

```go
var numCPU = runtime.NumCPU() // 逻辑cpu核心数
var numCPU = runtime.GOMAXPROCS(numCPU) // 最大可用cpu数量
```





# 使用channel控制两个协程交替运行

```go
func main() {
    // ch用来同步两个协程交替执行
    ch := make(chan int)
    // ch_end用来阻塞主程序，让两个协程可以执行完
    ch_end := make(chan int)
    go func() {
        for i := 1; i <= 100; i++ {
            ch <- 1
            if i % 2 == 0 {
                fmt.Println(i)
            }
        }
        ch_end <- 1
    }()
    go func() {
        for i := 1; i <= 100; i++ {
            <-ch
            if i % 2 != 0 {
                fmt.Println(i)
            }
        }
    }()
    <-ch_end
}
```





# 实现timeout

```go
func TimeOut(timeout time.Duration) {
    ch_timeout := make(chan bool, 1) // ch_timeout用来阻塞，当timeout时触发break
    go func() {
        time.Sleep(timeout)
        ch_timeout <- true
    }()

    ch_do := make(chan int, 1)
    go func() {
        time.Sleep(3e9)
        ch_do <- 1
    }()

    select {
    case i := <- ch_do:
        fmt.Println("do something, id:", i)
    case <-ch_timeout:
        fmt.Println("timeout")
        break // 跳出select
    }
}
```





# 实现迭代器

```go
// 迭代器
func iterator(iterable []interface{}) chan interface{}{
    yield := make(chan interface{})
    go func() {
        for i := 0; i < len(iterable); i++ {
            yield <- iterable[i]
        }
        close(yield)
    }()
    return yield
}

// 获取下一个元素
func next(iter chan interface{}) interface{} {
    for v := range iter {
        return v
    }
    return nil
}

func main() {
    nums := []interface{}{1, 2, 3, 4, 5}
    iter := iterator(nums)  // iter为chan，iterator为iter的生产者
    for v := next(iter); v != nil; v = next(iter) {  // next为iter的消费者
      // 当next消费一个iter中的元素，iterator会马上往iter中生产一个元素
      // 当next消费速度大于iterator，next会阻塞
        fmt.Println(v)
    }
}
```





# 参考

[Go实践：Goroutine（go协程）调度原理及应用](https://www.jianshu.com/p/b9247868c61b)

[Go语言基础之并发](https://www.jianshu.com/p/8ba98c5096a0)
