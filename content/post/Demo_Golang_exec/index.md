---
title: "Golang执行linux命令"
date: 2022-01-11T00:02:45+08:00
lastmod: 2022-01-22T00:02:45+08:00
draft: false
keywords: []
description: ""
tags: ["golang", "os/exec"]
categories: ["golang"]
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



# Doc

```go

type Cmd struct {
	Path string
	Args []string
	Env []string
	Dir string
	Stdin io.Reader
	Stdout io.Writer
	Stderr io.Writer
	ExtraFiles []*os.File
	SysProcAttr *syscall.SysProcAttr
	Process *os.Process
	ProcessState *os.ProcessState
}

```



一般用法

```go
package main
 
import (
	"fmt"
	"io/ioutil"
	"log"
	"os/exec"
	"syscall"
)
 
func main() {
 
	cmd := exec.Command("/bin/bash", "-c", "ls -l")  //不加第一个第二个参数会报错
 
    //cmd.Stdout = os.Stdout // cmd.Stdout -> stdout  重定向到标准输出，逐行实时打印
	//cmd.Stderr = os.Stderr // cmd.Stderr -> stderr
    //也可以重定向文件 cmd.Stderr= fd (文件打开的描述符即可)
 
	stdout, _ := cmd.StdoutPipe()   //创建输出管道
	defer stdout.Close()
	if err := cmd.Start(); err != nil {
		log.Fatalf("cmd.Start: %v")
	}
 
	fmt.Println(cmd.Args) //查看当前执行命令
 
	cmdPid := cmd.Process.Pid //查看命令pid
	fmt.Println(cmdPid)
 
	result, _ := ioutil.ReadAll(stdout) // 读取输出结果
	resdata := string(result)
	fmt.Println(resdata)
 
	var res int
	if err := cmd.Wait(); err != nil {
		if ex, ok := err.(*exec.ExitError); ok {
			fmt.Println("cmd exit status")
			res = ex.Sys().(syscall.WaitStatus).ExitStatus() //获取命令执行返回状态，相当于shell: echo $?
		}
	}
	fmt.Println(res)
}


```

```go
package main

import (
	"fmt"
	"io/ioutil"
	"os/exec"
)

func ExecCommand(strCommand string) string {
	cmd := exec.Command("/bin/bash", "-c", strCommand)

	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		fmt.Println("Execute failed when Start:" + err.Error())
		return ""
	}

	out_bytes, _ := ioutil.ReadAll(stdout)
	stdout.Close()

	if err := cmd.Wait(); err != nil {
		fmt.Println("Execute failed when Wait:" + err.Error())
		return ""
	}
	return string(out_bytes)
}

func main() {
	strData := ExecCommand("ls")
	fmt.Println("ls execute finished:\n" + strData)
}



```





# 获取命令输出

## CombinedOutput



```go
cmd := exec.Command("ls", "-lah")
out, err := cmd.CombinedOutput()
if err != nil {
  log.Fatalf("cmd.Run() failed with %s\n", err)
}
fmt.Printf("combined out:\n%s\n", string(out))
```



## 分开处理stdout和stderr



```go
cmd := exec.Command("ls", "-lah")
var stdout, stderr bytes.Buffer
cmd.Stdout = &stdout
cmd.Stderr = &stderr
err := cmd.Run()
if err != nil {
  log.Fatalf("cmd.Run() failed with %s\n", err)
}
outStr, errStr := string(stdout.Bytes()), string(stderr.Bytes())
fmt.Printf("out:\n%s\nerr:\n%s\n", outStr, errStr)
```



## io.MultiWriter



```go
var stdoutBuf, stderrBuf bytes.Buffer
cmd := exec.Command("ls", "-lah")
stdoutIn, _ := cmd.StdoutPipe()
stderrIn, _ := cmd.StderrPipe()
var errStdout, errStderr error
stdout := io.MultiWriter(os.Stdout, &stdoutBuf)
stderr := io.MultiWriter(os.Stderr, &stderrBuf)
err := cmd.Start()
```









# 修改环境变量

修改特定cmd的环境变量：cmd.Env

```go

cmd := exec.Command("programToExecute")
additionalEnv := "FOO=bar"
newEnv := append(os.Environ(), additionalEnv))
cmd.Env = newEnv
out, err := cmd.CombinedOutput()
if err != nil {
	log.Fatalf("cmd.Run() failed with %s\n", err)
}
fmt.Printf("%s", out)
```



修改整个进程的生命周期的环境变量：os.Setenv

```go
func RunCmd(cmd *exec.Cmd) (*bufio.Scanner, bool) {
	os.Setenv("LANG", "C")
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil { // 开始执行cmd
		fmt.Println(err)
	}
	var buf1, buf2 bytes.Buffer // buf1用于return scanner，buf2用于判断cmd的输出结果是否大于1行
	buf := io.MultiWriter(&buf1, &buf2) // 写入buf中的stream会同时写到buf1和buf2
	io.Copy(buf, stdout) // stdout的内容copy to buf
	content, _ := io.ReadAll(&buf2) 
	return bufio.NewScanner(&buf1), strings.Count(string(content), "\n") > 1
}

cmd := exec.Command("sh", "-c", "cat /etc/passwd")
stdoutScanner, _ := RunCmd(cmd)
for stdoutScanner.Scan() {
  ...
}
```





# 管道

例1

```go
package main
import (
    "bytes"
    "io"
    "os"
    "os/exec"
)
func main() {
    c1 := exec.Command("ls")
    c2 := exec.Command("wc", "-l")
    r, w := io.Pipe() 
    c1.Stdout = w
    c2.Stdin = r
    var b2 bytes.Buffer
    c2.Stdout = &b2
    c1.Start()
    c2.Start()
    c1.Wait()
    w.Close()
    c2.Wait()
    io.Copy(os.Stdout, &b2)
}


package main
import (
    "os"
    "os/exec"
)
func main() {
    c1 := exec.Command("ls")
    c2 := exec.Command("wc", "-l")
    c2.Stdin, _ = c1.StdoutPipe()
    c2.Stdout = os.Stdout
    _ = c2.Start()
    _ = c1.Run()
    _ = c2.Wait()
}
```

例2

```go
package main
import (
	"fmt"
	"os/exec"
)
func main() {
	cmd := "cat /proc/cpuinfo | egrep '^model name' | uniq | awk '{print substr($0, index($0,$4))}'"
	out, err := exec.Command("bash", "-c", cmd).Output()
	if err != nil {
		fmt.Printf("Failed to execute command: %s", cmd)
	}
	fmt.Println(string(out))
}
```





# 文件是否存在

```go

// 检查文件或目录是否存在
// 如果由 filename 指定的文件或目录存在则返回 true，否则返回 false
func Exist(filename string) bool {
    _, err := os.Stat(filename)
    return err == nil || os.IsExist(err)
}
```





# 命令参数是字符串，无法扩展

```go
//用cmd /c 命令
context := "nc" + " 127.0.0.1 " + clinetPort + " >> " + path
cmd := exec.Command("cmd.exe", `/c`+context)
out, err := cmd.Output()

// or
dbDir = `C:/Users/zzz/Desktop/临时目录`
context := fmt.Sprintf("/c cd %s&%s&sqlite3.exe QQ.db < dump.sql", dbDir, dbDir[0:2])
cmd := exec.Command(`cmd.exe`, dmt)
```



# 检查命令是否存在



```go
func checkLsExists() {
	path, err := exec.LookPath("ls")
	if err != nil {
		fmt.Printf("didn't find 'ls' executable\n")
	} else {
		fmt.Printf("'ls' executable is in '%s'\n", path)
	}
}
```





# 获取exit code

> 待验证

```go
package main
 
import (
	"fmt"
	"io/ioutil"
	"log"
	"os/exec"
	"syscall"
)
 
func main() {
 
	cmd := exec.Command("/bin/bash", "-c", "ls -l")  //不加第一个第二个参数会报错
 
    //cmd.Stdout = os.Stdout // cmd.Stdout -> stdout  重定向到标准输出，逐行实时打印
	//cmd.Stderr = os.Stderr // cmd.Stderr -> stderr
    //也可以重定向文件 cmd.Stderr= fd (文件打开的描述符即可)
 
	stdout, _ := cmd.StdoutPipe()   //创建输出管道
	defer stdout.Close()
	if err := cmd.Start(); err != nil {
		log.Fatalf("cmd.Start: %v")
	}
 
	fmt.Println(cmd.Args) //查看当前执行命令
 
	cmdPid := cmd.Process.Pid //查看命令pid
	fmt.Println(cmdPid)
 
	result, _ := ioutil.ReadAll(stdout) // 读取输出结果
	resdata := string(result)
	fmt.Println(resdata)
 
	var res int
	if err := cmd.Wait(); err != nil {
		if ex, ok := err.(*exec.ExitError); ok {
			fmt.Println("cmd exit status")
			res = ex.Sys().(syscall.WaitStatus).ExitStatus() //获取命令执行返回状态，相当于shell: echo $?
		}
	}
 
	fmt.Println(res)
}
```





# 参考

[使用os/exec执行命令](https://colobu.com/2017/06/19/advanced-command-execution-in-Go-with-os-exec/)
