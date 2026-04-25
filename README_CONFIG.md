# 配置文件使用指南

## 📁 配置文件

### `config.json` - JSON 配置文件（已支持）

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
    "/",
    "/health",
    "/public/**",
    "/api/*/*/public/**"
    "/*/public/**"
  ],
  "blocked_paths": [
    "/internal/**",
    "/admin/**"
  ]
}
```

---

## 🚀 启动方式

### 1. 自动加载配置文件
```bash
./jwt-antpath-forwardauth
```

程序会自动查找当前目录下的 `config.json` 文件。

**成功加载时输出**：
```
✅ 成功加载配置文件: config.json
📋 白名单路径 (3 条):
   - /
   - /health
   - /*/public/**
🚫 拦截路径 (2 条):
   - /internal/**
   - /admin/**
🚀 Zig JWT Gateway Listening on 0.0.0.0:9090
```

### 2. 配置文件不存在时使用默认配置
```
⚠️ 无法加载配置文件 config.json (FileNotFound), 使用默认配置
🚀 Zig JWT Gateway Listening on 0.0.0.0:9090
```

---

## 📋 配置项说明

### 1. 服务器配置（server）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `listen_addr` | string | `"0.0.0.0:9090"` | 监听地址 |

**示例**：
```json
{
  "server": {
    "listen_addr": "127.0.0.1:8080"
  }
}
```

---

### 2. JWT 配置（jwt）

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `secret_key` | string | `"gaming-partner-secret-key"` | HMAC-SHA256 签名密钥 |
| `header_key` | string | `"Authorization"` | 提取 JWT 的 HTTP Header 名称 |

**示例**：
```json
{
  "jwt": {
    "secret_key": "your-production-secret-key",
    "header_key": "X-Token"
  }
}
```

---

### 3. 白名单配置（whitelist）

**数组类型**，支持三种匹配模式：

#### 精确匹配
```json
"whitelist": ["/", "/health", "/api/v1/users"]
```

#### 双星号 `/**` 匹配（多目录通配符）
```json
"whitelist": ["/*/public/**", "/api/v1/docs/**"]
```

**匹配规则**：
```
✅ /prefix/public/index.html       → 匹配
✅ /prefix/public/a/b/c/d.js       → 匹配
❌ /api/v1/public/callback  → 不匹配（路径前缀多了一层）
```

#### 单星号 `*` 匹配（单级通配符）
```json
"whitelist": [
  "/*/public/**"
  "/api/*/*/public/**"
]
```

**匹配规则**：
```
✅ /api/v1/payment/public/callback     → 匹配（* 匹配 v1）
✅ /api/v2/payment/public/callback     → 匹配（* 匹配 v2）
✅ /api/v1/test/public/callback        → 匹配（第 1 个 * 匹配 v1，第 2 个匹配 test）
❌ /api/v1/test/payment/public/callback → 不匹配（* 不能跨越 /）
```

**关键限制**：
- `*` 匹配的部分**不能包含 `/` 字符**
- `*` 只能匹配单个路径片段（两个 `/` 之间的内容）

---

### 4. 拦截规则（blocked_paths）

**数组类型**，优先级高于白名单：

```json
"blocked_paths": [
  "/internal/**",
  "/admin/**",
  "/debug/**"
]
```

**示例场景**：
```
请求: GET /internal/metrics
结果: 403 Forbidden（即使有有效 JWT）

请求: GET /admin/users
结果: 403 Forbidden（即使有有效 JWT）
```

---

## 🎯 实际使用场景

### 场景 1：第三方支付回调

```json
{
  "whitelist": [
    "/api/*/webhook/stripe/**",
    "/api/*/payment/paypal/callback/**",
    "/api/*/payment/alipay/notify/**"
  ]
}
```

**匹配示例**：
```
✅ /api/v1/webhook/stripe/charge.succeeded
✅ /api/v2/payment/paypal/callback/order/123
✅ /api/prod/payment/alipay/notify/async
```

---

### 场景 2：多版本 API + 公开资源

```json
{
  "whitelist": [
    "/health",
    "/health/**",
    "/static/**",
    "/assets/**",
    "/api/*/public/**",
    "/docs/**",
    "/swagger-ui/**"
  ],
  "blocked_paths": [
    "/internal/**",
    "/admin/**"
  ]
}
```

---

### 场景 3：你的需求 - `/api/*/*/public/**`

```json
{
  "whitelist": [
    "/api/*/*/public/**"
  ]
}
```

**匹配示例**：
```
✅ /api/v1/payment/public/callback
✅ /api/v2/order/public/callback
✅ /api/prod/tenant/public/callback
❌ /api/v1/test/payment/public/callback  （* 不能跨越 /）
```

**解释**：
- 第 1 个 `*` 匹配 `v1`、`v2`、`prod` 等单个片段
- 第 2 个 `*` 匹配 `payment`、`order`、`tenant` 等单个片段
- `/**` 匹配后续的任意层级

---

## ⚠️ 常见配置错误

### 错误 1：误用 `/**` 匹配中间路径
```json
// ❌ 错误：期望匹配 /api/v1/payment/public/callback
{
  "whitelist": ["/public/**"]
}

// ✅ 正确：使用单星号匹配中间路径
{
  "whitelist": ["/api/*/payment/public/**"]
}
```

### 错误 2：单星号跨越目录
```json
// ❌ 错误：期望 * 匹配 v1/payment
{
  "whitelist": ["/api/*/public/**"]
}

// ✅ 正确：为每个层级使用单独的 *
{
  "whitelist": ["/api/*/*/public/**"]
}
```

### 错误 3：忘记配置拦截规则
```json
// ❌ 风险：内部路径未配置拦截
{
  "whitelist": ["/health", "/api/*/public/**"]
}

// ✅ 安全：显式配置拦截规则
{
  "blocked_paths": ["/internal/**", "/admin/**"],
  "whitelist": ["/health", "/api/*/public/**"]
}
```

---

## 🔄 配置优先级

```
1. 拦截规则（blocked_paths）     ← 最高优先级
   ↓
2. 白名单（whitelist）
   ↓
3. JWT 验证                      ← 最低优先级
```

**流程图**：
```
请求到达
   ↓
检查是否在 blocked_paths？
   ├─ 是 → 403 Forbidden（立即拒绝）
   └─ 否 ↓
检查是否在 whitelist？
   ├─ 是 → 200 OK（直接放行）
   └─ 否 ↓
检查 JWT Token 是否有效？
   ├─ 是 → 200 OK + 注入 Claims Headers
   └─ 否 → 401 Unauthorized
```

---

## 🛠️ 配置文件模板

### 开发环境（config-dev.json）
```json
{
  "server": {
    "listen_addr": "127.0.0.1:9090"
  },
  "jwt": {
    "secret_key": "dev-key-not-for-production",
    "header_key": "Authorization"
  },
  "whitelist": [
    "/",
    "/health",
    "/public/**",
    "/api/*/payment/public/**"
  ],
  "blocked_paths": [
    "/internal/**"
  ]
}
```

### 生产环境（config-prod.json）
```json
{
  "server": {
    "listen_addr": "0.0.0.0:9090"
  },
  "jwt": {
    "secret_key": "${JWT_SECRET_KEY}",
    "header_key": "Authorization"
  },
  "whitelist": [
    "/health",
    "/api/v1/payment/public/**",
    "/api/v2/payment/public/**",
    "/static/**",
    "/assets/**"
  ],
  "blocked_paths": [
    "/internal/**",
    "/admin/**",
    "/debug/**"
  ]
}
```

---

## 📊 配置文件位置

```
jwt-antpath-forwardauth/
├── config.json          ← 配置文件（放在这里）
├── zig-out/
│   └── bin/
│       └── jwt-antpath-forwardauth  ← 可执行文件
└── src/
    └── app.zig
```

**启动方式**：
```bash
# 方式 1：在项目根目录启动
cd jwt-antpath-forwardauth
./zig-out/bin/jwt-antpath-forwardauth

# 方式 2：指定配置文件路径（需要代码支持）
./zig-out/bin/jwt-antpath-forwardauth-forwardauth --config /etc/jwt-gateway/config.json
```

---

## 🔍 调试技巧

### 1. 查看配置加载日志
启动时会打印所有白名单和拦截路径。

### 2. 测试路径匹配
```bash
# 测试白名单路径（应返回 200）
curl http://localhost:9090/api/v1/payment/public/callback

# 测试拦截路径（应返回 403）
curl http://localhost:9090/internal/metrics

# 测试 JWT 验证（应返回 200 + Claims Headers）
curl -H "Authorization: Bearer <valid_jwt_token>" http://localhost:9090/api/users
```

### 3. 验证 JWT Claims 注入
```bash
curl -v -H "Authorization: Bearer <jwt_token>" http://localhost:9090/api/users

# 响应头应包含 JWT payload 中的所有 claims：
# sub: user123
# user_id: 10086
# email: admin@example.com
# role: admin
```

---

## ✅ 快速开始

### 1. 复制配置文件模板
```bash
cp config.json config-prod.json
```

### 2. 编辑配置文件
```bash
vim config.json
```

### 3. 修改关键配置
```json
{
  "jwt": {
    "secret_key": "your-very-strong-secret-key-here"
  },
  "whitelist": [
    "/*/public/**"
    "/api/*/*/public/**"
  ]
}
```

### 4. 启动服务
```bash
./zig-out/bin/jwt-antpath-forwardauth
```

---

## 📝 下一步

- ✅ JSON 配置文件支持（已完成）
- 🔲 命令行参数指定配置文件路径（`--config`）
- 🔲 环境变量替换（`${ENV_VAR}` 语法）
- 🔲 配置热重载（文件变化时自动重新加载）
- 🔲 配置验证工具（检查路径格式是否正确）
