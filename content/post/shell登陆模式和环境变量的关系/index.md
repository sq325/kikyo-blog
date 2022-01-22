---
title: "shell login和no-login的区别"
date: 2022-01-12T23:14:38+08:00
lastmod: 2022-01-22T23:14:38+08:00
draft: false
keywords: []
description: ""
tags: ["linux", "bash"]
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

shell的登陆方式决定其环境变量的加载，其中interactive shell和non-interactive shell之间的区别很好理解，本文重点介绍bash下的login和no-login。

<!--more-->

---

# 判断

判断当前shell

- interactive or non-interactive
- login or no-login

```bash
echo $- # 569XZilms,有i则表示interactive
echo $PS1 # 有则表示interactive

echo $0 # -开头表示login，否则no-login
```





# login和no-login

login和no-login的登陆方式

```bash
# login
$ su - 
$ su -l 
$ su --login 
$ su USERNAME - 
$ su -l USERNAME 
$ su --login USERNAME 
$ sudo -i
ssh user@ip

# no-login
su 
bash
```

## login

**一个login shell的启动过程**

1. /bin/login程序读取/etc/passwd文件，并登陆对应用户
2. 启动此用户对应的shell(/etc/passwd定义)

/bin/login是在登录会话时在用户 ID 下执行的第一个过程，它会设置$0变量（通常是 shell 程序可执行文件的名称，例如 bash），并带有“-”字符。例如Bash shell，$0=-bash。

当 bash 被调用为 Login shell，具体的配置加载流程

- -> `登陆进程` 调用 `/etc/profile`
- -> `/etc/profile` 调用 `/etc/profile.d/` 下的脚本
- -> `登陆进程` 调用 `~/.bash_profile`
- -> `~/.bash_profile` 调用 `~/.bashrc`
- -> `~/.bashrc` 调用 `/etc/bashrc`

以上流程其实很好理解，login指的是登陆指定的用户，自然需要加载用户特定的配置信息，这里主要涉及两个文件: `/etc/profile`和`~/.bash_profile`，一个是所有用户和shell都需要加载的用户配置，另一个是特定shell需要加载的用户配置。通常在 `~/.bash_profile`中还回去加载特定shell说需要的配置。



## no-login

一个 Non Login shell 并不通过 login 进程开始。通过$0参数会看到shell的名称前无"-"。

当 bash 被调用为 Non Login shell，具体的配置加载流程

- -> `Non-login` 进程调用 `~/.bashrc`
- -> `~/.bashrc` 调用 `/etc/bashrc`
- -> `/etc/bashrc` 调用 `/etc/profile.d/ 下的脚本`

因为无需登陆到特定用户，所以不会加载用户配置，比如各种profile文件，只会加载特定shell的配置，如`~/.bashrc`。

# 总结

|                 | login                                          | no-login                                     |
| --------------- | ---------------------------------------------- | -------------------------------------------- |
| interactive     | `/etc/profile`, `~/.bash_profile`, `$ENV`      | `/etc/bash.bashrc`, `~/.bashrc`, `$ENV`      |
| non-interactive | `/etc/profile`, `~/.bash_profile`, `$BASH_ENV` | `/etc/bash.bashrc`, `~/.bashrc`, `$BASH_ENV` |



> - **login** shell: A login shell logs you into the system as a specific user, necessary for this is a username and password. When you hit ctrl+alt+F1 to login into a virtual terminal you get after successful login: a login shell (that is interactive). Sourced files:
>   - `/etc/profile` and `~/.profile` for Bourne compatible shells (and `/etc/profile.d/*`)
>   - `~/.bash_profile` for bash
>   - `/etc/zprofile` and `~/.zprofile` for zsh
>   - `/etc/csh.login` and `~/.login` for csh
> - **non-login** shell: A shell that is executed without logging in, necessary for this is a current logged in user. When you open a graphic terminal in gnome it is a non-login (interactive) shell. Sourced files:
>   - `/etc/bashrc` and `~/.bashrc` for bash
> - **interactive** shell: A shell (login or non-login) where you can interactively type or interrupt commands. For example a gnome terminal (non-login) or a virtual terminal (login). In an interactive shell the prompt variable must be set (`$PS1`). Sourced files:
>   - `/etc/profile` and `~/.profile`
>   - `/etc/bashrc` or `/etc/bash.bashrc` for bash
> - **non-interactive** shell: A (sub)shell that is probably run from an automated process you will see neither input nor output when the calling process don't handle it. That shell is normally a non-login shell, because the calling user has logged in already. A shell running a script is always a non-interactive shell, but the script can emulate an interactive shell by prompting the user to input values. Sourced files:
>   - `/etc/bashrc` or `/etc/bash.bashrc` for bash (but, mostly you see this at the beginning of the script: `[ -z "$PS1" ] && return`. That means don't do anything if it's a non-interactive shell).
>   - depending on shell; some of them read the file in the `$ENV` variable.

# 配置文件详细介绍

- /etc/profile：此文件为系统的环境变量，它为每个用户设置环境信息，当用户第一次登录时，该文件被执行。并从 `/etc/profile.d` 目录的配置文件中搜集 shell 的设置。这个文件，是任何用户登陆操作系统以后都会读取的文件（如果用户的 shell 是 csh 、tcsh 、zsh，则不会读取此文件），用于获取系统的环境变量，只在登陆的时候读取一次。

- /etc/bashrc：在执行完 /etc/profile 内容之后，如果用户的 SHELL 运行的是 bash ，那么接着就会执行此文件。另外，当每次一个新的 bash shell 被打开时, 该文件被读取。每个使用 bash 的用户在登陆以后执行完 /etc/profile 中内容以后都会执行此文件，在新开一个 bash 的时候也会执行此文件。因此，如果你想让每个使用 bash 的用户每新开一个 bash 和每次登陆都执行某些操作，或者给他们定义一些新的环境变量，就可以在这个里面设置。

- ~/.bash_profile：每个用户都可使用该文件输入专用于自己使用的 shell 信息。当用户登录时，该文件仅仅执行一次，默认情况下，它设置一些环境变量，最后执行用户的 .bashrc 文件。单个用户此文件的修改只会影响到他以后的每一次登陆系统。因此，可以在这里设置单个用户的特殊的环境变量或者特殊的操作，那么它在每次登陆的时候都会去获取这些新的环境变量或者做某些特殊的操作，但是仅仅在登陆时。

- ~/.bashrc：该文件包含专用于单个人的 bash shell 的 bash 信息，当登录时以及每次打开一个新的 shell 时, 该该文件被读取。单个用户此文件的修改会影响到他以后的每一次登陆系统和每一次新开一个 bash 。因此，可以在这里设置单个用户的特殊的环境变量或者特殊的操作，那么每次它新登陆系统或者新开一个 bash ，都会去获取相应的特殊的环境变量和特殊操作。

- **~/.bash_profile 或 ~/.bash_login 或 ~/.profile：属于使用者个人配置，只会读取一个文件。



# 参考

[Login shell 和 Non-Login shell 的区别](https://halysl.github.io/2020/04/02/Login-shell-和-Non-Login-shell-的区别/)

[login/non-login and interactive/non-interactive shells](https://unix.stackexchange.com/questions/170493/login-non-login-and-interactive-non-interactive-shells)
