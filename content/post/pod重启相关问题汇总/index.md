---
title: "pod重启相关问题汇总"
date: 2024-03-30T23:59:42+08:00
lastmod: 2024-03-30T23:59:42+08:00
draft: true
keywords: []
description: ""
tags: ["k8s", "Golang"]
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





# 多容器 Pod 重启策略

## 问题一：什么情况下整个 Pod 会发生被 Kill（重启）

1. initContainer运行失败，并且 Pod的重启策略是Never
   
    > 加上 Pod 的重启策略是 Never 的判断，是因为如果 Pod 的重启策略是 Always 或者 OnFailure，那么即使 initContainer 运行失败，Pod 也会被重启。这是因为 Pod 的重启策略是 Always 或者 OnFailure 时，kubelet 会根据 Pod 的重启策略来决定是否重启 Pod，而不是根据 initContainer 的运行状态来决定是否重启 Pod。
    >
    
    ```go
    initFailed := initLastStatus != nil && isInitContainerFailed(initLastStatus)
    if initFailed && !shouldRestartOnFailure(pod) { // init失败，并且重启策略是Never
        changes.KillPod = true
    }
    ```
    
2. 没有运行中的容器并且也没容器需要启动
   
    ```go
    if keepCount == 0 && len(changes.ContainersToStart) == 0 {
        changes.KillPod = true
    }
    ```
    
3. 沙盒容器（pause）发生变化，整个 Pod会发生从重启
   
    > 沙盒容器指的是 Pod 的 pause 容器，它是 Pod 中所有容器的父容器，所有容器都是 pause 容器的子容器。当 Pod 中的容器发生变化时，比如容器的定义发生变化，或者容器的状态发生变化，kubelet 都会检查 Pod 的 pause 容器是否发生变化，如果发生变化，那么 kubelet 会删除旧的 pause 容器，并创建一个新的 pause 容器，然后重启 Pod 中的所有容器。
    >
    
    ```go
    createPodSandbox, attempt, sandboxID := runtimeutil.PodSandboxChanged(pod, podStatus)
    ...
    changes := podActions{
      KillPod:           createPodSandbox,
    ...}
    ```
    

## 问题二：多容器的 Pod，什么情况下容器会重启但 Pod 不会重启

除了问题一中 Pod 被 kill 的情况，其他情况都只是容器被重启，而 Pod 本身不会重启。比如多容器 Pod 中的某个容器失败，那么只有这个容器会被重启，Pod 不会受影响。

## 问题三：容器会在什么情况下重启

1. 容器的定义(`container.spec`)发生变化
   
    ```go
    if _, _, changed := containerChanged(&container, containerStatus); changed &&
        (!isInPlacePodVerticalScalingAllowed(pod) ||
            kubecontainer.HashContainerWithoutResources(&container) != containerStatus.HashWithoutResources) {
        // ...
        restart = true
    }
    ```
    
2. 容器未通过liveness探针
   
    ```go
    else if liveness, found := m.livenessManager.Get(containerStatus.ID); found && liveness == proberesults.Failure {
        // ...
        reason = reasonLivenessProbe
    }
    ```
    
3. 容器未通过启动探针（startup probe）
   
    ```go
    else if startup, found := m.startupManager.Get(containerStatus.ID); found && startup == proberesults.Failure {
        // ...
        reason = reasonStartupProbe
    }
    ```
    
4. 容器需要进行垂直缩放（vertical scaling），并且缩放策略要求重启容器，我们也需要重启它
   
    > 垂直缩放指的是 Pod 中的容器资源发生变化，比如容器的 CPU 和内存资源发生变化。
    >
    
    ```go
    else if isInPlacePodVerticalScalingAllowed(pod) && !m.computePodResizeAction(pod, idx, containerStatus, &changes) {
        // ...
        continue
    }
    ```
    

## 问题四：修改 imagePullPolicy 会导致 Pod 发生重启吗？

从源码看，任何 Deployment 资源变动都会触发控制器的同步策略，控制器会根据 Deployment 的更新策略来决定是否更新 Pod。Deployment 的更新策略有两种，一种是 `Recreate`，另一种是 `RollingUpdate`。如果 Deployment 的更新策略是 `Recreate`，那么所有 Pod 都会被删除，然后重新创建 Pod。如果 Deployment 的更新策略是 `RollingUpdate`，则会滚动的重启 Pod。

```go
func (dc *DeploymentController) syncDeployment(ctx context.Context, key string) error {
  ...
  switch d.Spec.Strategy.Type {
  case apps.RecreateDeploymentStrategyType:
    return dc.rolloutRecreate(ctx, d, rsList, podMap)
  case apps.RollingUpdateDeploymentStrategyType:
    return dc.rolloutRolling(ctx, d, rsList)
  ...
}
```

但这个问题其实没这么简单，从上面**问题一**中可知，Pod 被 kill 的条件并没有修改 `Pod.spec`，理论上可以通过直接修改 `Pod.spec`，实现在 Pod 不发生重启的情况下修改 `imagePullPolicy`。但其实这是行不通的，原因很简单，直接 `kubectl edit pod <podName>` 会报错：

```
spec: Forbidden: pod updates may not change fields other than `spec.containers[*].image`, `spec.initContainers[*].image`, `spec.activeDeadlineSeconds`, `spec.tolerations` (only additions to existing tolerations) or `spec.terminationGracePeriodSeconds`
```

一旦 Pod 被创建，大部分 spec 里的字段就不允许修改了。﻿`imagePullPolicy` 就是其中之一。而通过 `kubectl edit deploy <name>` 修改 `imagePullPolicy` ，其本质上是通过修改控制器使得 Pod 被新的实例替换，而不是原地修改 Pod 的 ﻿`imagePullPolicy` 。

# 探针相关问题

## 问题一：偶发探测未通过会导致 Pod 重启或被摘流吗？

不会，k8s 执行探测时做了足够的冗余，有两个参数控制探测失败时的重试次数：`maxProbeRetries` 和 `failureThreshold`，其中 `failureThreshold` 可以在 yaml 中设置，`maxProbeRetries` 是没法修改的。

```go
const maxProbeRetries = 3 // probe最多重试三次
...
for i := 0; i < retries; i++ { // 重试3次，有1次成功测认为成功
	result, output, err = pb.runProbe(ctx, probeType, p, pod, status, container, containerID)
	...
}
```

```go
if (result == results.Failure && w.resultRun < int(w.spec.FailureThreshold)) ... {
  return true
}
```

简单说，如果是默认值 `maxProbeRetries = 3` 和 `failureThreshold = 3`，通过最少只需一次探测，失败则需要连续9次探测都失败。如果`failureThreshold = 0`，也需要连续3次测都失败才会触发重启或摘流。
