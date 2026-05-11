# jwt-antpath-forwardauth — 手动部署

## 前置条件

```bash
# 1. seccomp profile (io_uring 需要，所有 K8s worker 节点执行)
kubectl apply -f ../seccomp/io_uring-allowed.json
# 或手动复制:
# scp ../seccomp/io_uring-allowed.json root@node:/var/lib/kubelet/seccomp/
```

## 部署

```bash
# 1. 填密钥
vim secret.yaml   # 修改 JWT_SECRET_KEY

# 2. 创建 namespace
kubectl create namespace gw --dry-run=client -o yaml | kubectl apply -f -

# 3. 部署
kubectl apply -f secret.yaml
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f hpa.yaml
```

## 验证

```bash
kubectl get pods -n gw -l app=jwt-antpath-forwardauth
kubectl port-forward svc/jwt-antpath-forwardauth-svc -n gw 9090:80
curl http://localhost:9090/health
```

## 注意

- **不需要 Gateway API HTTPRoute** — jwt-antpath-forwardauth 由 Traefik 通过 ForwardAuth 内部调用
- **不需要 Ingress** — 同理由
- JWT_SECRET_KEY 必须与 gaming-partner user 服务的 gpJwtSecret 一致
