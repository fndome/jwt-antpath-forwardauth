# seccomp profile — io_uring

jwt-antpath-forwardauth 依赖 sws（基于 io_uring），需要 `io_uring_setup` / `io_uring_enter` / `io_uring_register` 三个 syscall。

## 什么时候需要此 profile

| containerd 版本 | io_uring | 操作 |
|:---|:---|:---|
| **v1.6+** | 默认放行 | 不需要此 profile |
| **< v1.6** | 默认禁止 | 需要使用 `io_uring-allowed.json` |

> 当前集群 containerd 版本 ≥ 2.2，io_uring 默认可用。

## 如果需要使用

1. 将 `io_uring-allowed.json` 放到所有 K8s 节点的 `/var/lib/kubelet/seccomp/` 目录
2. 在 Deployment 中引用：

```yaml
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: Localhost
          localhostProfile: seccomp/io_uring-allowed.json
      containers:
        - ...
```

> **注意**：该 profile 使用 `defaultAction: SCMP_ACT_ALLOW`（不拦截任何 syscall）。如需严格限制，建议基于 containerd 默认 seccomp profile 追加 io_uring 三个 syscall。
