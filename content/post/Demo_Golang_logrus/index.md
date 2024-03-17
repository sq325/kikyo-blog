---
title: "[Demo] Golang logrus范例"
date: 2022-01-05T19:15:41+08:00
lastmod: 2022-01-05T19:15:41+08:00
draft: false
keywords: []
description: ""
tags: ["golang", 'logrus']
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

# 日切日志

> linux操作系统有最大文件限制，需要定期分割日志文件

## rotatelogs

思路

- rotatelogs周期性产生日志文件
- New函数始终return当前日志文件的Writer
- rotatelogs通过软链，不断更新软链指向的日子文件

### Doc

```go
import rotatelogs "github.com/lestrrat-go/file-rotatelogs"

func New(p string, options ...Option) (*RotateLogs, error) //RotateLogs是一个Writer

type Option interface {
 Name() string
 Value() interface{}
}
func WithLinkName(s string) Option // 生成软链，指向最新日志文件
func WithMaxAge(d time.Duration) Option
func WithRotationTime(d time.Duration) Option
```

### Demo

```go
import (
 rotatelogs "github.com/lestrrat-go/file-rotatelogs"
  "github.com/sirupsen/logrus"
)
func init() {
  logName := "./logs/prometheus.log"
 logrus.SetFormatter(&logrus.TextFormatter{TimestampFormat: "2006-01-02 15:04:05"})
 logrus.SetLevel(logrus.InfoLevel)
 writer, err := rotatelogs.New(
  logName+".%Y_%m_%d",
  rotatelogs.WithLinkName(logName),
  rotatelogs.WithMaxAge(time.Duration(24*30)*time.Hour), // 保存30天
  rotatelogs.WithRotationTime(time.Duration(24)*time.Hour),  // 日切
 )

 if err != nil {
  logrus.Fatalf("init log error: %w", err)
 }
 logrus.SetOutput(writer)
}

```

## lumberjack

> 另一个切割日志的pkg

### Doc

- `lumberjack.Logger`实现`io.WriteCloser`

```go
import "gopkg.in/natefinch/lumberjack.v2"

type Logger struct {
    Filename string // 日志文件名
    MaxSize int // 日志文件达到多大时触发日志文件的分割，MB
    MaxAge int // 日志文件最大的留存时间，天
    MaxBackups int // 分割日志的保留个数
    LocalTime bool // 分割日志的时间是否使用本地时间
    Compress bool // 是否压缩被分割的日志
}
```

### Demo

```go
package main

import (
 "github.com/rifflock/lfshook"
 "github.com/sirupsen/logrus"
 "gopkg.in/natefinch/lumberjack.v2"
)
func main(){
 errLogger := &lumberjack.Logger{
  Filename: "err.txt", //日志文件路径
  MaxSize: 5, //每个日志文件保存的最大尺寸，单位：M
  MaxBackups: 7, //日志文件最多保存多少个备份
  MaxAge: 7, //日志文件最多保存多少天
  Compress: true, //是否压缩
 }
 //logrus.AddHook(h)

 lfHook := lfshook.NewHook(lfshook.WriterMap{
  logrus.ErrorLevel: errLogger,
  logrus.FatalLevel: errLogger,
 },nil)
 logrus.AddHook(lfHook)
 for  {
  logrus.Error("error msg")
 }
```

# 定制

## 函数

```go
logrus.SetLevel(logruslevel)
logrus.SetOutput(writer)
logrus.SetReportCaller(true)
logrus.SetFormatter(&log.TextFormatter{
    TimestampFormat: "2006-01-02 15:04:05",
    ForceColors:  true,
    EnvironmentOverrideColors: true,
    // FullTimestamp:true,
    // DisableLevelTruncation:true,
})
```

## 第三方格式

```go
package main

import (
  nested "github.com/antonfisher/nested-logrus-formatter"
  "github.com/sirupsen/logrus"
)

func main() {
  logrus.SetFormatter(&nested.Formatter{
    HideKeys:    true,
    FieldsOrder: []string{"component", "category"},
  })

  logrus.Info("info msg")
}

// Feb  8 15:22:59.077 [INFO] info msg
```

# 输出到多个Writer

## Doc

```go
import "github.com/sirupsen/logrus"

type Logger struct {
 Out io.Writer
 Hooks LevelHooks
 Formatter Formatter
 ReportCaller bool
 Level Level
 ExitFunc exitFunc
}
type Entry struct {
 Logger *Logger
 Data Fields
 Time time.Time
 Level Level
 Message string
 ...
}
```

## Demo

```go
package main

import (
 "github.com/lestrrat-go/file-rotatelogs"
 "github.com/pkg/errors"
 "github.com/rifflock/lfshook"
 log "github.com/sirupsen/logrus"
 "path"
 "time"
)

func ConfigLocalFilesystemLogger(logPath string, logFileName string, maxAge time.Duration, rotationTime time.Duration) {
 baseLogPath := path.Join(logPath, logFileName)
 writer, err := rotatelogs.New(
  baseLogPath+"-%Y%m%d%H%M.log",
  rotatelogs.WithLinkName(baseLogPath), 
  rotatelogs.WithMaxAge(maxAge),             // 文件最大保存时间
  rotatelogs.WithRotationTime(rotationTime), // 日志切割时间间隔
 )
 if err != nil {
  log.Errorf("config local file system logger error. %+v", errors.WithStack(err))
 }
  writer1, _ = os.OpenFile("err.log", os.O_RDWR|os.O_CREATE, 0755)
  
 lfHook := lfshook.NewHook(lfshook.WriterMap{
  log.DebugLevel: writer, // 为不同级别设置不同的输出目的
  log.InfoLevel:  os.Stderr,
  log.WarnLevel:  os.Stdout,
  log.ErrorLevel: writer1,
  log.FatalLevel: writer,
  log.PanicLevel: writer,
 }, &log.TextFormatter{DisableColors: true})
 log.SetReportCaller(true) //将函数名和行数放在日志里面
 log.AddHook(lfHook)
}

func main() {
 //ConfigLocalFilesystemLogger1("log")
 ConfigLocalFilesystemLogger("D:/benben", "sentalog", time.Second*60*3, time.Second*60)
 for {
        log.Debug("调试信息")
        log.Info("提示信息")
        log.Warn("警告信息")
        log.Error("错误信息")
  time.Sleep(500 * time.Millisecond)
 }
}


```

```go
mw := io.MultiWriter(os.Stdout, logFile)
logrus.SetOutput(mw)
```

```go
requestLogger := log.WithFields(log.Fields{"request_id": request_id, "user_ip": user_ip})
requestLogger.Info("something happened on that request") # will log request_id and user_ip
requestLogger.Warn("something not great happened")
```

# 使用logger对象

> 适合习惯面向对象编程的人使用

```go
package main

import (
 "github.com/sirupsen/logrus"
 "os"
)

// logrus提供了New()函数来创建一个logrus的实例。
// 项目中，可以创建任意数量的logrus实例。
var log = logrus.New()

func main() {
 log.Out = os.Stdout
  log.Formatter = &logrus.JSONFormatter{}
 log.WithFields(logrus.Fields{
  "animal": "walrus",
  "size":   10,
 }).Info("A group of walrus emerges from the ocean")
}



```

## 默认std对象

如果不新建logger对象，则会使用std这个默认的logger对象

```go
// github.com/sirupsen/logrus/exported.go
var (
  std = New()
)

func StandardLogger() *Logger {
  return std
}

func SetOutput(out io.Writer) {
  std.SetOutput(out)
}

func SetFormatter(formatter Formatter) {
  std.SetFormatter(formatter)
}

func SetReportCaller(include bool) {
  std.SetReportCaller(include)
}

func SetLevel(level Level) {
  std.SetLevel(level)
}

```

# hook

- 不同目的地的分发
- 额外添加字段

```go
// logrus在记录Levels()返回的日志级别的消息时会触发HOOK，
// 按照Fire方法定义的内容修改logrus.Entry。
// 写入日志时拦截，修改logrus.Entry
type Hook interface {
 Levels() []Level
 Fire(*Entry) error
}

type DefaultFieldHook struct {
}

func (hook *DefaultFieldHook) Fire(entry *log.Entry) error {
    entry.Data["appName"] = "MyAppName"
    return nil
}

func (hook *DefaultFieldHook) Levels() []log.Level {
    return log.AllLevels
}
logger.AddHook(DefaultFieldHook)

```

# gin

```go
// a gin with logrus demo

var log = logrus.New()

func init() {
 // Log as JSON instead of the default ASCII formatter.
 log.Formatter = &logrus.JSONFormatter{}
 // Output to stdout instead of the default stderr
 // Can be any io.Writer, see below for File example
 f, _ := os.Create("./gin.log")
 log.Out = f
 gin.SetMode(gin.ReleaseMode)
 gin.DefaultWriter = log.Out
 // Only log the warning severity or above.
 log.Level = logrus.InfoLevel
}

func main() {
 // 创建一个默认的路由引擎
 r := gin.Default()
 // GET：请求方式；/hello：请求的路径
 // 当客户端以GET方法请求/hello路径时，会执行后面的匿名函数
 r.GET("/hello", func(c *gin.Context) {
  log.WithFields(logrus.Fields{
   "animal": "walrus",
   "size":   10,
  }).Warn("A group of walrus emerges from the ocean")
  // c.JSON：返回JSON格式的数据
  c.JSON(200, gin.H{
   "message": "Hello world!",
  })
 })
 // 启动HTTP服务，默认在0.0.0.0:8080启动服务
 r.Run()
}
```

# 参考

[日志框架logrus](http://www.lsdcloud.com/go/middleware/logrus.html)

[golang日志库logrus的使用](https://xieys.club/go-logrus/)
