---
title: "hugo处理图片的方式"
date: 2021-09-13T18:24:31+08:00
lastmod: 2021-09-13T18:24:31+08:00
draft: true
keywords: []
description: ""
tags: ["hugo"]
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

这里介绍两种在文章中插入图片的方式，各有利弊，可以根据情况选择。

<!--more-->



# 把图片放到`static/`下

把图片全部放到`static/`文件夹下，并在文章中

![image-20210913173736916](image-20210913173736916.png)

# 把图片





```powershell
content/
│  about.md
│
└─post
    ├─21年9月书摘/
    │      index.md
    │
    ├─hugo处理图片的方式/
    │      image-20210913173736916.png
    │      index.md
    │
    └─hugo如何选择正确的模板进行渲染/
            index.md
            layouts.svg
            list_page.svg
            list_page_html.svg
            page.svg
            single_page.svg
            single_page_html.svg
            term_page.svg
```

