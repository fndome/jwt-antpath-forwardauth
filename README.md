# JWT-AntPath-ForwardAuth

> 🚀 专为 `ForwardAuth` 架构设计的高性能 JWT 鉴权网关。零依赖、零 GC、纳秒级延迟。基于 Zig 构建。

`jwt-antpath-forwardauth` 不是一个完整的反向代理，而是一个**轻量级、确定性的鉴权决策服务**。它专为 Traefik、Envoy 或 Nginx 的 `ForwardAuth` 模式设计，仅处理请求头鉴权，不转发 Body，以极致的性能和透明的逻辑守护 API 边界。

---

## ✨ 核心特性

| 特性 | 说明 |
|:---|:---|
| 🔐 **JWT HS256 验签** | 原生 `HMAC-SHA256` 验证，支持 `exp` 过期检查。无解释器开销。 |
| 🌐 **Spring AntPath 匹配** | 完整支持 `*`（单段）与 `**`（多段）通配符。启动时预编译，运行时零分配匹配。 |
| 🛡️ **路径访问控制** | 声明式 `whitelist`（免验证放行）与 `blocked_paths`（直接拒绝）。 |
| ⏱️ **对齐窗口限流** | 工业级固定窗口算法。时间槽强制对齐整秒，彻底消除边界突发攻击。 |
| 📤 **Claims 动态注入** | 验签通过后，自动将 JWT Payload 所有字段解析并注入为 HTTP 响应头（如 `user_id`, `role`）。 |
| ⚡ **零依赖 & 确定性** | 纯 Zig 标准库。无 GC、无反射、无隐藏控制流。二进制体积 `< 2MB`。 |
| 📝 **JSON 配置驱动** | 单一 `config.json` 管理密钥、路径规则、限流阈值。启动即加载。 |

---

## 🏗️ 架构定位：为什么是 ForwardAuth？

在传统网关中，鉴权逻辑往往与路由、负载均衡、协议转换耦合。`jwt-antpath-forwardauth` 采用**决策与执行分离**的现代架构：

```
客户端请求 (h2/h3)
       ↓
[Traefik / Envoy / Nginx]  ← 负责协议终结、路由、TLS、Body 缓冲
       ↓ (仅转发 Header 子请求)
[ jwt-antpath-forwardauth ] ← 仅做鉴权决策，不碰 Body
       ↓ (返回 200 + Claims Headers / 401 / 403 / 429)
[Traefik / Envoy / Nginx]  ← 接收决策，注入 Headers，转发至后端 Pod
```

**优势**：
- ✅ **零 Body 开销**：Traefik 拦截 Body，鉴权服务只读 Header，内存占用恒定。
- ✅ **协议无关**：无论外部是 HTTP/1.1、h2 还是 h3，内部鉴权链路始终保持 HTTP/1.1 文本协议，解析极快。
- ✅ **横向扩展**：无状态设计，可随意多副本部署。

---

## 📦 快速开始

### 1. 编译
```bash
# 要求：Zig 0.16.0
zig build
```
编译产物位于 `zig-out/bin/jwt-antpath-forwardauth`（仅支持 Linux，基于 `io_uring`）。

### 2. 配置 (`config.json`)
在项目根目录创建 `config.json`：
```json
{
  "server": {
    "listen_addr": "0.0.0.0:9090"
  },
  "jwt": {
    "secret_key": "gaming-partner-secret-key",
    "header_key": "Authorization"
  },
  "whitelist": [
    "/health",
    "/api/*/*/public/**",
    "/*/public/**"
    "/static/**"
  ],
  "blocked_paths": [
    "/internal/**",
    "/admin/**"
  ],
  "rate_limits": [
    {
      "path_pattern": "/*/public/**",
      "qps": 3000,
      "burst": 6000,
      "window_seconds": 60
    },
    {
      "path_pattern": "/**",
      "qps": 100,
      "burst": 200,
      "window_seconds": 1
    }
  ]
}
```

### 3. 启动
```bash
./zig-out/bin/jwt-antpath-forwardauth
```
**启动日志示例**：
```
✅ 成功加载配置文件: config.json
📋 白名单路径 (4 条):
   - /health
   - /api/*/*/public/**
   - /*/public/**
   - /static/**
🚫 拦截路径 (2 条):
   - /internal/**
   - /admin/**
⏱️  限流规则 (2 条):
   - /*/public/**: 3000 请求/60秒, burst=6000
   - /**: 100 请求/1秒, burst=200
🚀 JWT Gateway Listening on 0.0.0.0:9090
```

---

## 🔌 集成示例 (Traefik Kubernetes CRD)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: jwt-forwardauth
spec:
  forwardAuth:
    address: "http://jwt-antpath-forwardauth:9090"
    # 仅透传鉴权必需的 Header
    authRequestHeaders:
      - "Authorization"
      - "X-Forwarded-For"
      - "X-Forwarded-Proto"
    # 指定需要从鉴权服务注入到后端请求的 Claims
    authResponseHeaders:
      - "sub"
      - "user_id"
      - "role"
      - "email"
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: api-routes
spec:
  routes:
    - match: PathPrefix(`/api`)
      middlewares:
        - name: jwt-forwardauth
      services:
        - name: user-service
          port: 8080
```

---

## 🎯 路径匹配规则说明

| 模式 | 匹配示例 | 说明 |
|:---|:---|:---|
| `/healthz` | `/healthz` | 精确匹配 |
| `/api/**` | `/api/v1/users`, `/api/a/b/c` | `**` 匹配零个或多个目录层级 |
| `/api/*/public/**` | `/api/v1/public/callback` | `*` 匹配单个路径片段（不能跨 `/`） |
| `/api/*/*/public/**` | `/api/v1/payment/public/...` | 多个 `*` 依次匹配独立片段 |

---

## 🛡️ 鉴权决策流程

```
请求到达
   ↓
1. 检查 blocked_paths？ → 是 → 403 Forbidden
   ↓ 否
2. 检查 rate_limits？   → 超限 → 429 Too Many Requests
   ↓ 未超限
3. 检查 whitelist？     → 是 → 200 OK (直接放行)
   ↓ 否
4. 提取 JWT Token → 验证签名 & 过期？
   ├─ 失败 → 400 (数据不完整) / 401 (签名错误/过期)
   └─ 成功 → 200 OK + 注入 Claims Headers
```

---

## 📐 设计哲学

- **拒绝黑盒**：没有 GC 停顿，没有隐式控制流。每一行内存分配、每一次系统调用都透明可见。
- **工具而非框架**：不接管你的生命周期，不定义你的路由。它只做一件事：回答“这个请求能否通过”。
- **计算税的最小化**：JWT 验签是安全链路必须支付的“过路费”。本服务用 Zig 将这笔税压至物理极限（纳秒级），不浪费业务 Pod 的算力。
- **生产级健壮性**：完整的 `errdefer` 内存回滚、ET 模式部分写入重注册、对齐窗口防突发、优雅退出零 FD 泄漏。

---

## ⚙️ 编译与运行环境

- **操作系统**：Linux (依赖 `io_uring` 与 `accept4`)
- **编译器**：Zig `0.16.0` 或更高版本
- **外部依赖**：无（仅使用 Zig 标准库）
- **协议**：HTTP/1.1（专为 ForwardAuth 子请求优化，无需 h2/h3 终结）

---

## 📜 许可证

本项目采用 [MIT License](LICENSE) 开源。欢迎在生产环境中使用。
