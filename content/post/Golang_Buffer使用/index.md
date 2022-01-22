---
title: "Golang 流处理"
date: 2022-01-09T16:33:42+08:00
lastmod: 2022-01-22T16:33:42+08:00
draft: true
keywords: []
description: ""
tags: ["golang"]
categories: ["技术Demo"]
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



Go中常用的三种流处理数据结构

- bufio
- bytes.Buffer
- strings.Builder和strings.Reader



其中strings.Builder主要用来拼接字符串，bytes.Buffer和bufio用来减少磁盘io操作的次数，提高io性能。

`bufio VS bytes.Buffer`：两者都提供一层缓存功能，它们的不同主要在于 bufio 针对的是**文件到内存**的缓存，而 bytes.Buffer 的针对的是**内存到内存**的缓存

# bytes.Buffer

> bytes.Buffer 是一个实现了读写方法的可变大小的字节缓冲。本类型的零值是一个空的可用于读写的缓冲。

```go
func runCmd(cmd *exec.Cmd) (*bufio.Scanner, bool) {

	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil { // 开始执行cmd
		fmt.Println(err)
	}
	var buf1, buf2 bytes.Buffer 
	buf := io.MultiWriter(&buf1, &buf2) // 使用指针
	io.Copy(buf, stdout) // stdout读完即被清空
	content, _ := io.ReadAll(&buf2) // buf2读完被清空
	return bufio.NewScanner(&buf1), string(content) != ""
}
```



要使用指针，即*bytes.Buffer，而不是byte.Buffer本身

```go
type Buffer struct {} // 一个实现Read和Write的可变尺寸[]byte

// 既可以从[]byte也可以从string创建Buffer
func NewBuffer(buf []byte) *Buffer
func NewBufferString(s string) *Buffer
```

Read

```go
func (b *Buffer) Read(p []byte) (n int, err error) // 从b中读取len(p)内容存到p([]byte)
func (b *Buffer) ReadString(delim byte) (line string, err error) // 以delim为终止符读取b中的数据。如果读取的数据不是以delim为终止，err != nil
func (b *Buffer) WriteTo(w io.Writer) (n int64, err error) // 从b中读取数据并写入w



```



Write

```go
func (b *Buffer) ReadFrom(r io.Reader) (n int64, err error) // 从r读取数据到b
```









```go
// 声明
var b bytes.Buffer       				//直接定义一个Buffer变量，不用初始化，可以直接使用
b := new(bytes.Buffer)   				//使用New返回Buffer变量
b := bytes.NewBuffer(s []byte)   		//从一个[]byte切片，构造一个Buffer
b := bytes.NewBufferString(s string)	//从一个string变量，构造一个Buffer

// 写入数据
b.Write(d []byte) (n int, err error)   			//将切片d写入Buffer尾部
b.WriteString(s string) (n int, err error) 		//将字符串s写入Buffer尾部
b.WriteByte(c byte) error  						//将字符c写入Buffer尾部
b.WriteRune(r rune) (n int, err error)    		//将一个rune类型的数据放到缓冲区的尾部
b.ReadFrom(r io.Reader) (n int64, err error)	//从实现了io.Reader接口的可读取对象写入Buffer尾部


// 读取
//读取 n 个字节数据并返回，如果 buffer 不足 n 字节，则读取全部
b.Next(n int) []byte

//一次读取 len(p) 个 byte 到 p 中，每次读取新的内容将覆盖p中原来的内容。成功返回实际读取的字节数，off 向后偏移 n，buffer 没有数据返回错误 io.EOF
b.Read(p []byte) (n int, err error)

//读取第一个byte并返回，off 向后偏移 n
b.ReadByte() (byte, error)

//读取第一个 UTF8 编码的字符并返回该字符和该字符的字节数，b的第1个rune被拿掉。如果buffer为空，返回错误 io.EOF，如果不是UTF8编码的字符，则消费一个字节，返回 (U+FFFD,1,nil)
b.ReadRune() (r rune, size int, err error)

//读取缓冲区第一个分隔符前面的内容以及分隔符并返回，缓冲区会清空读取的内容。如果没有发现分隔符，则返回读取的内容并返回错误io.EOF
b.ReadBytes(delimiter byte) (line []byte, err error)

//读取缓冲区第一个分隔符前面的内容以及分隔符并作为字符串返回，缓冲区会清空读取的内容。如果没有发现分隔符，则返回读取的内容并返回错误 io.EOF
b.ReadString(delimiter byte) (line string, err error)

//将 Buffer 中的内容输出到实现了 io.Writer 接口的可写入对象中，成功返回写入的字节数，失败返回错误
b.WriteTo(w io.Writer) (n int64, err error)
```

```go
package main

import (
	"os"
	"fmt"
	"bytes"
)

func main() {
    file, _ := os.Open("./test.txt")    
    buf := bytes.NewBufferString("Hello world ")    
    buf.ReadFrom(file)              //将text.txt内容追加到缓冲器的尾部    
    fmt.Println(buf.String())
}
```





```go
type Buff struct {
	Buffer *bytes.Buffer
	Writer *bufio.Writer
}

// 初始化
func NewBuff() *Buff {
	b := bytes.NewBuffer([]byte{})
	return &Buff{
		Buffer: b,
		Writer: bufio.NewWriter(b),
	}
}

func (b *Buff) WriteString(str string) error {
	_, err := b.Writer.WriteString(str)
	return err
}

func (b *Buff) SaveAS(name string) error {
	file, err := os.OpenFile(name, os.O_WRONLY|os.O_TRUNC|os.O_CREATE, 0666)
	if err != nil {
		return err
	}
	defer file.Close()

	if err := b.Writer.Flush(); err != nil {
		return nil
	}

	_, err = b.Buffer.WriteTo(file)
	return err
}

func main() {
	var b = NewBuff()

	b.WriteString("haah")
}
```







# bufio

> bufio是给Reader加上读的buffer，给Writer加上写的buffer

```go
func NewReader(rd io.Reader) *Reader
func NewReaderSize(rd io.Reader, size int) *Reader

func NewWriter(w io.Writer) *Writer
func NewWriterSize(w io.Writer, size int) *Writer

type ReadWriter struct {
	*Reader
	*Writer
}
func NewReadWriter(r *Reader, w *Writer) *ReadWriter


```



bufio包提供了有缓冲的io，它定义了两个结构体，分别是Reader和Writer, 它们也分别实现了io包中io.Reader和io.Writer接口, 通过传入一个io.Reader的实现对象和一个缓冲池大小参数，可以构造一个bufio.Reader对象，根据bufio.Reader的相关方法便可读取io.Reader中数据流，因为带有缓冲池，读数据会先读到缓冲池，再次读取会先去缓冲池读取，这样减少了io操作，提高了效率；

```go

```









`func (b *Reader) Read(p []byte) (n int, err error)` 具体读取流程如下：

- 当缓存区有内容的时，将缓存区内容读取到p并清空缓存区；
- 当缓存区没有内容的时候且len(p)>len(buf),即要读取的内容比缓存区还要大，直接读取文件；
- 当缓存区没有内容的时候且len(p)<len(buf),即要读取的内容比缓存区小，缓存区从文件读取内容充满缓存区，并将p填满（此时缓存区有剩余内容）
- 以后再次读取时缓存区有内容，将缓存区内容全部填入p并清空缓存区；

`func (b *Writer) Write(p []byte) (nn int, err error) `具体写入流程如下：

- 判断buf中可用容量是否可以放下 p；如果能放下，直接把p拼接到buf后面，即把内容放到缓冲区
- 如果缓冲区的可用容量不足以放下，且此时缓冲区是空的，直接把p写入文件即可
- 如果缓冲区的可用容量不足以放下，且此时缓冲区有内容，则用p把缓冲区填满，把缓冲区所有内容写入文件，并清空缓冲区；



# strings.builder

strings.builder可以高效的写入、拼接字符串，其内部封装了一个字节数组，写入时其实是将传入的字节append到内部的字节数组上

```go
type Builder struct {
    addr *Builder // of receiver, to detect copies by value
    buf  []byte // 存放字符串
}
```

```go
func (b *Builder) WriteString(s string) (int, error) { // s写入Builder
 b.copyCheck()
 b.buf = append(b.buf, s...)
 return len(s), nil
}

func (b *Builder) String() string // Builder拼接成string
func (b *Builder) Write(p []byte) (int, error) // p中数据写入Builder
```



拼接字符串

> 推荐使用Builder

```go
// 使用strings.Builder
var builder strings.Builder
s1 := "pre "
s2 := "after"
builder.Grow(len(s1)+len(s2)) // 预先分配Builder底层[]byte的cap
builder.WriteString("pre ")
builder.WriteString("after")
builder.String() // pre after

//使用strings.Join
func Join(elems []string, sep string) string

s := []string{"foo", "bar", "baz"}
fmt.Println(strings.Join(s, ", ")) // foo, bar, baz

// 使用bytes.Buffer
buf := new(bytes.Buffer)
buf.WriteString("pre ")
buf.WriteString("after ")
buf.String() // pre after
```









# Reader

> 流数据，文件、[]byte、string和bytes.Buffer常被转化为Reader。

io.Reader只能读取一次，即为空。

```text
file
[]byte
string             ->          io.Reader
bytes.Buffer
```



```go
io.ReadAll(reader io.Reader)
io.Copy(dst io.Writer, reader io.Reader)
// 读取后Reader即没有内容，不能读取两次
```















