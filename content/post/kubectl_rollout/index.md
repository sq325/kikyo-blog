---
title: "kubectl rollout 原理解析"
date: 2024-05-03T14:31:28+08:00
lastmod: 2024-05-13T10:31:28+08:00
draft: false
keywords: []
description: ""
tags: ["k8s"]
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

`kubectl rollout` 系列命令用于管理 k8s 的工作负载（workloads） ，包括 Deployment、StatefulSet 和 DaemonSet，能让我们轻松操作它们的历史版本，实现重启与版本回滚操作。本文结合源码，分析 `kubectl rollout` 各个子命令的实现原理。

<!--more-->

# Kubernetes 工作负载的版本控制机制

k8s 在实现历史版本管理方面，根据不同的工作负载类型采用了不同的策略。以我们经常使用的 Deployment 为例，一个版本对应一个 ReplicaSet 对象，每次更新都会创建一个新的 ReplicaSet 对象，通过调整新旧 `ReplicaSet.spec.replicas` 的数量来逐步将旧 pod 替换成新 pod。

需要特别指出，版本更新指的是 `.spec.template` 的变更，其他字段的更新并不会触发新版本的创建。比如更新了 `deploy.metadata.annotations`，`deploy.spec.replicas` 等字段。

StatefulSet 和 DaemonSet 则是通过 ControllerRevision 对象来实现，ControllerRevision 对象记录了每个版本的 pod 模板，通过替换 `StatefulSet/DaemonSet.spec.template` 来实现版本回滚。

所有控制器通过 `.spec.revisionHistoryLimit` 字段控制保留的历史版本数量，超出此数量的版本将被删除。

# rollout 系列命令

`kubectl rollout` :

```cmd
Available Commands:
  history       显示上线历史
  pause         将所指定的资源标记为已暂停
  restart       Restart a resource
  resume        恢复暂停的资源
  status        显示上线的状态
  undo          撤销上一次的上线
```

其中 `restart/undo` 会对工作负载进行变更操作，变更过程中可以通过 `pause/resume/status` 暂停/恢复/查看工作负载的更新。`history` 可以查看工作负载的历史版本。

## history

`history` 命令根据不同的工作负载类型，选择合适的处理函数。这一命令涉及的处理逻辑主要包括 Deployment、DaemonSet 以及 StatefulSet 这几种控制器。对于 Deployment 类型，`history` 会通过获取与之关联的历史 ReplicaSets 来执行任务；而对于 DaemonSet 和 StatefulSet 类型，则通过获取它们各自的历史 ControllerRevisions 来管理和回滚历史版本。

**Deployment**

```go
func (h *DeploymentHistoryViewer) GetHistory(namespace, name string) (map[int64]runtime.Object, error) {
  // 获取历史 ReplicaSets
	allRSs, err := getDeploymentReplicaSets(h.c.AppsV1(), namespace, name)
	...
	result := make(map[int64]runtime.Object)
	for _, rs := range allRSs {
		v, err := deploymentutil.Revision(rs)
		...
		result[v] = rs
	}
	return result, nil
}
```

**DaemonSet 和 StatefulSet**

```go
func controlledHistoryV1(...) {
  ...
  // 获取历史 ControllerRevisions
	historyList, err := apps.ControllerRevisions(namespace).List(context.TODO(), metav1.ListOptions{LabelSelector: selector.String()})
	...
}
```

## pause / resume

`pause/resume` 命令允许用户暂停或者恢复 Kubernetes 集群中的工作负载（工作负载）更新。这两个命令的核心功能是通过更改资源对象的 `.spec.paused` 字段来实现的。具体操作是将 `.spec.paused` 设置为 true 以暂停更新，或者设置为 false 以恢复更新。

**pause**

```go

func defaultObjectPauser(obj runtime.Object) ([]byte, error) {
	switch obj := obj.(type) {
	...
	case *appsv1.Deployment:
		...
		obj.Spec.Paused = true // 设置为 true，暂停更新
		return runtime.Encode(scheme.Codecs.LegacyCodec(appsv1.SchemeGroupVersion), obj)
	...
}
```

**resume**

```go

func defaultObjectResumer(obj runtime.Object) ([]byte, error) {
	switch obj := obj.(type) {
	...
	case *appsv1.Deployment:
		...
		obj.Spec.Paused = false // 设置为 false，恢复更新
		return runtime.Encode(scheme.Codecs.LegacyCodec(appsv1.SchemeGroupVersion), obj)
	...
}
```

## undo

`undo` 命令允许用户通过指定 `--to-revision=0` 参数来回退到先前的某个版本。

**Deployment** 版本回退流程如下：

1. 获取要回退版本的 ReplicaSet 对象
2. 将当前 Deployment 的 `spec.template` 部分替换为已获取 ReplicaSet 的 `spec.template`
3. 调用 k8s patch 接口传递以上操作的 patch json

```go
func (r *DeploymentRollbacker) Rollback(obj runtime.Object, updatedAnnotations map[string]string, toRevision int64, dryRunStrategy cmdutil.DryRunStrategy) (string, error) {
	...
	deployment, err := r.c.AppsV1().Deployments(namespace).Get(context.TODO(), name, metav1.GetOptions{})
	...
  // 获取指定版本的 ReplicaSet
	rsForRevision, err := deploymentRevision(deployment, r.c, toRevision)
	...
  // 生成 patch 接口所需的 json body
	patchType, patch, err := getDeploymentPatch(&rsForRevision.Spec.Template, annotations)
	...
  // 调用接口 patch 接口
	if _, err = r.c.AppsV1().Deployments(namespace).Patch(context.TODO(), name, patchType, patch, patchOptions); err != nil {
		...
	}
	...
}

// getDeploymentPatch 函数生成调用 patch 接口传递的 json
func getDeploymentPatch(podTemplate *corev1.PodTemplateSpec, annotations map[string]string) (types.PatchType, []byte, error) {
	patch, err := json.Marshal([]interface{}{
		map[string]interface{}{
			"op":    "replace",
			"path":  "/spec/template",
			"value": podTemplate,
		},
		map[string]interface{}{
			"op":    "replace",
			"path":  "/metadata/annotations",
			"value": annotations,
		},
	})
	return types.JSONPatchType, patch, err
}
```

**DaemonSet** 和 **StatefulSet** 版本回退的原理大致相同：

1. 获取要回退版本的 ControllerRevision 对象
2. ControllerRevision 的 data 字段保存着某一版本的 `spec.template` 内容，将当前的 `spec.template` 替换为已获取 `ControllerRevision.data`
与 Deployment 不同的是，DaemonSet 和 StatefulSet 的版本回退操作是通过 patch 接口的 StrategicMergePatchType 类型来实现的，而不是 JSONPatchType。StrategicMergePatchType 是一种 Kubernetes 特有的 Patch 类型，能够智能处理列表和复杂结构的合并。

```go
// DaemonSet 回退
func (r *DaemonSetRollbacker) Rollback(obj runtime.Object, updatedAnnotations map[string]string, toRevision int64, dryRunStrategy cmdutil.DryRunStrategy) (string, error) {
	...
	ds, history, err := daemonSetHistory(r.c.AppsV1(), accessor.GetNamespace(), accessor.GetName())
	...
  // toHistory 就是对应版本的 ControllerRevision
	toHistory := findHistory(toRevision, history)
	...
	// Restore revision
	if _, err = r.c.AppsV1().DaemonSets(accessor.GetNamespace()).Patch(context.TODO(), accessor.GetName(), types.StrategicMergePatchType, toHistory.Data.Raw, patchOptions); err != nil {
		return "", fmt.Errorf("failed restoring revision %d: %v", toRevision, err)
	}
	...
}

// StatefulSet 回退
func (r *StatefulSetRollbacker) Rollback(obj runtime.Object, updatedAnnotations map[string]string, toRevision int64, dryRunStrategy cmdutil.DryRunStrategy) (string, error) {
	...
	sts, history, err := statefulSetHistory(r.c.AppsV1(), accessor.GetNamespace(), accessor.GetName())
	...
	toHistory := findHistory(toRevision, history)
	...
	if _, err = r.c.AppsV1().StatefulSets(sts.Namespace).Patch(context.TODO(), sts.Name, types.StrategicMergePatchType, toHistory.Data.Raw, patchOptions); err != nil {
		return "", fmt.Errorf("failed restoring revision %d: %v", toRevision, err)
	}
	...
}
```

## Restart

`restart` 命令会对指定的工作负载对象进行重启操作，对于 Deployment，会根据更新策略（RollingUpdate/Recreate）来决定重启方式；对于 DaemonSet 和 StatefulSet，则是一个个重启 pod。

重启操作的原理是通过修改对象 template 的 annotation（`spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]`）为当前时间，从而触发控制器进行升级操作，如下源码所示：

```go
func defaultObjectRestarter(obj runtime.Object) ([]byte, error) {
	switch obj := obj.(type) {
	case *appsv1.Deployment:
		if obj.Spec.Paused {
			return nil, errors.New("can't restart paused deployment (run rollout resume first)")
		}
		if obj.Spec.Template.ObjectMeta.Annotations == nil {
			obj.Spec.Template.ObjectMeta.Annotations = make(map[string]string)
		}
		obj.Spec.Template.ObjectMeta.Annotations["kubectl.kubernetes.io/restartedAt"] = time.Now().Format(time.RFC3339)
		return runtime.Encode(scheme.Codecs.LegacyCodec(appsv1.SchemeGroupVersion), obj)

	case *appsv1.DaemonSet:
		if obj.Spec.Template.ObjectMeta.Annotations == nil {
			obj.Spec.Template.ObjectMeta.Annotations = make(map[string]string)
		}
		obj.Spec.Template.ObjectMeta.Annotations["kubectl.kubernetes.io/restartedAt"] = time.Now().Format(time.RFC3339)
		return runtime.Encode(scheme.Codecs.LegacyCodec(appsv1.SchemeGroupVersion), obj)

	case *appsv1.StatefulSet:
		if obj.Spec.Template.ObjectMeta.Annotations == nil {
			obj.Spec.Template.ObjectMeta.Annotations = make(map[string]string)
		}
		obj.Spec.Template.ObjectMeta.Annotations["kubectl.kubernetes.io/restartedAt"] = time.Now().Format(time.RFC3339)
		return runtime.Encode(scheme.Codecs.LegacyCodec(appsv1.SchemeGroupVersion), obj)
	...
}
```

具体的更新逻辑和 `undo` 类似，也是通过调用 patch 接口实现，使用的是 StrategicMergePatchType 类型的 patch。

```go
func (o RestartOptions) RunRestart() error {
	// 获取匹配的资源对象
	r := o.Builder().
		WithScheme(scheme.Scheme, scheme.Scheme.PrioritizedVersionsAllGroups()...).
		NamespaceParam(o.Namespace).DefaultNamespace().
		FilenameParam(o.EnforceNamespace, &o.FilenameOptions).
		LabelSelectorParam(o.LabelSelector).
		ResourceTypeOrNameArgs(true, o.Resources...).
		ContinueOnError().
		Latest().
		Flatten().
		Do()
	...
	infos, err := r.Infos() // info 代表一个资源对象

	// 计算 patches
	patches := set.CalculatePatches(infos, scheme.DefaultJSONEncoder(), set.PatchFn(o.Restarter))

	for _, patch := range patches {
		info := patch.Info
		...
		obj, err := resource.NewHelper(info.Client, info.Mapping).
			WithFieldManager(o.fieldManager).
			Patch(info.Namespace, info.Name, types.StrategicMergePatchType, patch.Patch, nil)
		...
		info.Refresh(obj, true) // 实施 patches
		printer, err := o.ToPrinter("restarted")
		...
	}
	return utilerrors.NewAggregate(allErrs)
}
```

如果对计算 patch 的详细步骤感兴趣，可以参看源码中的 `set.CalculatePatches` 函数，这里就不再展开了。

# 参考

[kubernetes 源码](https://github.com/kubernetes/kubernetes)
