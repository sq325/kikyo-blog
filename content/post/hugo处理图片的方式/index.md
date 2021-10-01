---
title: "hugo-处理图片的方式"
date: 2021-09-13T18:24:31+08:00
lastmod: 2021-09-15T00:24:31+08:00
draft: false
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

- 把图片放到`static/`下，在文章中使用绝对路径引用图片
- 把图片放到和文章同级目录下，通过相对路径引用图片

从最终效果来看，两种方法在构建后都能正确显示图片，但第一种方法的问题在于使用`hugo server -D`预览时无法正确加载图片，第二种方法可以在预览时正确加载图片，但会导致`content/{{section}}/`下多嵌套一层目录。

之所以把图片放到`static/`下，是因为hugo在构建时会把`static/`下所有内容移到`public/`下。构建后`content/`下的内容也会被移到`public/`下，这样相当于文章和图片有共同的根目录，在文章中使用绝对引用即可正确显示图片。

![image-20210913173736916](image-20210913173736916.png)

第二种方法是把图片和文章放在同级目录，比如`content/{{section}}/{{article_name}}/`，这样虽会显得`content/`下略显冗余，但可以在预览或构建后都正确显示图片。

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

