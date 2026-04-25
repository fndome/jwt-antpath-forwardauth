# JWT AntPath ForwardAuth Helm Chart

生产级 Helm Chart，用于在 Kubernetes 上部署 JWT AntPath ForwardAuth 网关。

## 功能特性

- ✅ **高可用部署**: 默认 2 副本 + Pod 反亲和性
- ✅ **自动扩缩容 (HPA)**: 基于 CPU/内存使用率
- ✅ **Pod 中断预算 (PDB)**: 保证升级期间的可用性
- ✅ **安全加固**: 非 root 用户、只读文件系统、能力限制
- ✅ **健康检查**: Liveness/Readiness 探针
- ✅ **Prometheus 集成**: ServiceMonitor 自动发现指标
- ✅ **配置管理**: ConfigMap + Secret 分离敏感信息

## 快速开始

### 1. 添加 Helm 仓库（如果需要）

```bash
helm repo add my-repo https://your-helm-repo.com
helm repo update
```

### 2. 安装 Chart

```bash
# 使用默认配置安装
helm install jwt-auth ./helm-chart -n auth-system --create-namespace

# 自定义 JWT 密钥安装
helm install jwt-auth ./helm-chart \
  -n auth-system \
  --create-namespace \
  --set jwtSecretKey="your-super-secret-key-at-least-32-chars"

# 使用 values 文件安装
helm install jwt-auth ./helm-chart \
  -n auth-system \
  --create-namespace \
  -f custom-values.yaml
```

### 3. 验证部署

```bash
kubectl get pods -n auth-system -l app.kubernetes.io/name=jwt-antpath-forwardauth
kubectl get svc -n auth-system -l app.kubernetes.io/name=jwt-antpath-forwardauth
kubectl get hpa -n auth-system
```

## 配置说明

### 核心参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `replicaCount` | `2` | 副本数量 |
| `image.repository` | `fndome/jwt-antpath-forwardauth` | 镜像仓库 |
| `image.tag` | `latest` | 镜像标签 |
| `jwtSecretKey` | 随机生成 | JWT 签名密钥（建议通过外部 Secret 管理） |
| `service.port` | `9090` | 服务端口 |

### 资源限制

```yaml
resources:
  limits:
    cpu: 500m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 64Mi
```

### 自动扩缩容

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
```

### Prometheus 监控

```yaml
serviceMonitor:
  enabled: true
  interval: 30s
  scrapeTimeout: 10s
```

## 与 Traefik 集成

### 1. 创建 Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: jwt-auth
  namespace: default
spec:
  forwardAuth:
    address: http://jwt-auth.auth-system.svc.cluster.local:9090
    trustForwardHeader: true
    authResponseHeaders:
      - X-Forwarded-User
```

### 2. 应用到 IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: my-app
          port: 80
      middlewares:
        - name: jwt-auth
  tls: {}
```

## 升级指南

```bash
# 升级 Chart
helm upgrade jwt-auth ./helm-chart -n auth-system

# 回滚到上一个版本
helm rollback jwt-auth -n auth-system

# 查看历史版本
helm history jwt-auth -n auth-system
```

## 卸载

```bash
helm uninstall jwt-auth -n auth-system
```

## 故障排查

### 查看日志

```bash
kubectl logs -n auth-system -l app.kubernetes.io/name=jwt-antpath-forwardauth
```

### 检查事件

```bash
kubectl get events -n auth-system --sort-by='.lastTimestamp'
```

### 测试端点

```bash
# 健康检查
kubectl port-forward svc/jwt-auth -n auth-system 9090:9090
curl http://localhost:9090/health

# 指标端点
curl http://localhost:9090/metrics
```

## 安全最佳实践

1. **JWT 密钥管理**: 使用外部 Secret 管理系统（如 HashiCorp Vault、AWS Secrets Manager）
2. **网络策略**: 限制只有 Traefik 可以访问认证服务
3. **TLS 加密**: 启用 mTLS 或 TLS 加密通信
4. **定期轮换**: 定期更新 JWT 密钥和证书

```yaml
# 示例：网络策略
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: jwt-auth-ingress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: jwt-antpath-forwardauth
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: traefik-system
      ports:
        - protocol: TCP
          port: 9090
```
