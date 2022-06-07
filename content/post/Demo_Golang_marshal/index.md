---
title: "[Demo] Go语言Marshal技巧"
date: 2022-01-05T23:37:14+08:00
lastmod: 2022-01-05T23:37:14+08:00
draft: false
keywords: []
description: ""
tags: ["golang", "json", "struct"]
categories: ["使用Demo"]
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

# 嵌套struct

避免使用`map[string]interface{}`

1. interface{}如果为map，则无法index
2. 由于是interface{}，编译器无法进行类型检查

```json
// result.json
{
  "params": {
    "alarmCenter": {
      "resourceIp": "10.6.47.22",
      "alarmTitle": "instanceDown",
      "app": "prometheus",
      "eventType": "triggle",
      "alarmValue": "0e+00",
      "alarmCreateTime": 1639637625663,
      "priority": 4,
      "alarmContent": "job=openapi,instance=..., 数据采集异常"
    }
  }
}
```



```go
type Result struct {
  Params struct {
    AlarmCenter struct {
      ResourceIp string `json:"resourceIp"`
      AlarmTitle string	`json:"alarmTitle"`
      App string `json:"app"`
      EventType string	`json:"eventType"`
      AlarmValue string	`json:"alarmValue"`
      AlarmCreateTime int64	`json:"alarmCreateTime"`
      Priority int	`json:"priority"`
      AlarmContent string	`json:"alarmContent"`
    } `json:"alarmCenter"`
  } `json:"params"`
}
```





# 使用struct tag

```go
Key type  `json:"name,opt1,opt2,opts..."`
```

```go
//不指定tag，默认使用变量名称。转换为json时，key为Filed。

//直接忽略key
`json:"-"`

//指定json的key的name
`json:"name"`

//零值忽略
`json:",omitempty"`
`json:"name,omitempty"`

//将value转化为string，支持string、int64、float64和bool
`json:",string"`


```

