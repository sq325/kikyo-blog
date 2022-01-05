---
title: "[Demo] Golang logrus范例"
date: 2022-01-05T19:15:41+08:00
lastmod: 2022-01-05T19:15:41+08:00
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



# 日切日志

```go
import (
	rotatelogs "github.com/lestrrat-go/file-rotatelogs"
  "github.com/sirupsen/logrus"
)
func init() {
  logName := "./logs/prometheusToZabbix.log"
	logrus.SetFormatter(&logrus.TextFormatter{TimestampFormat: "2006-01-02 15:04:05"})
	logrus.SetLevel(logruslevel)
	writer, err := rotatelogs.New(
		logName+".%Y_%m_%d",
		rotatelogs.WithLinkName(logName),
		rotatelogs.WithMaxAge(time.Duration(24*logRetentionTimes)*time.Hour), // 保存logRetentionTimes天
		rotatelogs.WithRotationTime(time.Duration(24)*time.Hour),             // 日切
	)
	if err != nil {
		logrus.Fatalf("init log error: %w", err)
	}
	logrus.SetOutput(writer)

	logrus.WithFields(logrus.Fields{
		"logRetentionTimes_day": logRetentionTimes,
		"logLevel":              logruslevel,
		"scrapeInterval":        conf.Prometheus.ScrapeInterval,
	}).Infoln("config")
}

```



# 打印多种level log

```go
```

