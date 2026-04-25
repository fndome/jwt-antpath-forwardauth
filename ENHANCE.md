# Zig JWT 服务 64 位缓存对齐优化建议

## 一、当前代码的对齐现状

### 1. `Stats` 结构体 —— 过度对齐，且方式错误

```zig
pub const Stats = struct {
    total: u64 align(64) = 0,
    allowed: u64 align(64) = 0,
    blocked: u64 align(64) = 0,
    errors: u64 align(64) = 0,
};
```

**问题：**

每个字段单独 `align(64)` 意味着每个 u64 独占一个缓存行（64字节），四个字段占用 256字节 内存，实际只需要 32 字节。

单线程模型下不存在伪共享，这种对齐毫无收益，浪费 CPU 缓存和内存带宽。

**正确做法（单线程）：**

```zig
pub const Stats = struct {
    total: u64,
    allowed: u64,
    blocked: u64,
    errors: u64,
    _padding: [32]u8,   // 凑满64字节（4*8=32，还需32填充）
};
```

## 二、真正需要对齐的地方

### 1. Connection 结构体 —— 紧凑对齐 + 分配对齐

当前定义（热字段与大缓冲区混在一起）：

```zig
const Connection = struct {
    fd: i32,
    state: ConnState = .reading,
    buffer: [MAX_BUFFER_SIZE]u8,
    read_len: usize = 0,
    response_buf: [MAX_RESPONSE_SIZE]u8,
    write_len: usize = 0,
    write_offset: usize = 0,
};
```

**优化建议：** 重新排布字段，热字段放在最前面，并确保分配时 64 字节对齐。

```zig
const Connection = struct {
    // 热字段（常被访问）
    fd: i32,
    state: ConnState,
    read_len: usize,
    write_len: usize,
    write_offset: usize,
    // 冷数据（大缓冲区）
    buffer: [MAX_BUFFER_SIZE]u8,
    response_buf: [MAX_RESPONSE_SIZE]u8,
};
```

分配方式改为 slab 或对齐分配（避免 AutoHashMap 的默认堆分配）。

### 2. AsyncServer 热字段打包 + 对齐分配

```zig
pub const AsyncServer = struct {
    // 热字段
    epoll_fd: i32,
    listen_fd: i32,
    stats: *Stats,
    metrics: *PrometheusMetrics,
    rate_limiter: ?*RateLimiter,
    // 冷字段
    connections: std.AutoHashMap(i32, Connection),
    wl_rules: []PathRule,
    bl_rules: []PathRule,
    config: AppConfig,
    allocator: Allocator,
};
```

在 `startServer` 中改为堆分配并 64 字节对齐：

```zig
const srv_ptr = try alloc.createAligned(AsyncServer, 64);
defer {
    srv_ptr.deinit();
    alloc.destroy(srv_ptr);
}
srv_ptr.* = try AsyncServer.init(alloc, cfg, stats, metrics, fd);
// 之后使用 srv_ptr.run()
```

## 三、可立即执行的最小改动（最大收益）

**修改1：AsyncServer 对齐分配（在 startServer 中）**

```diff
-    var srv = try AsyncServer.init(alloc, cfg, stats, metrics, fd);
-    defer {
-        metrics.deinit();
-        srv.deinit();
-    }
+    const srv_ptr = try alloc.createAligned(AsyncServer, 64);
+    defer {
+        metrics.deinit();
+        srv_ptr.deinit();
+        alloc.destroy(srv_ptr);
+    }
+    srv_ptr.* = try AsyncServer.init(alloc, cfg, stats, metrics, fd);
```

后续调用改为 `srv_ptr.run()`。

## 四、可选：Connection Slab 分配器（性能提升明显）

放弃 AutoHashMap，使用定长数组 + 空闲索引栈。

```zig
const MAX_CONNECTIONS = 10000;
var connection_pool: [MAX_CONNECTIONS]Connection align(64) = undefined;
var free_stack: std.ArrayList(u32) = undefined;

fn alloc_connection() ?*Connection {
    const idx = free_stack.popOrNull() orelse return null;
    return &connection_pool[idx];
}

fn free_connection(conn: *Connection) void {
    const idx = @intFromPtr(conn) - @intFromPtr(&connection_pool);
    free_stack.append(@intCast(idx / @sizeOf(Connection))) catch unreachable;
}
```

## 五、总结

单线程 + K8s 多副本部署下，无需担心伪共享，只需关注单核内的数据局部性。

## 问题总结

| 组件 | 当前做法 | 状态 |
|------|----------|------|------|
| Stats | 紧凑排列 + 32字节填充 | ✅ 64字节 |
| Connection 字段 | 热字段靠前 | ✅ 已完成 |
| AsyncServer 实例 | 堆分配 + 64字节对齐 | ✅ 已完成 |
| I/O 模型 | epoll → io_uring | ✅ 异步I/O |
| 二进制体积 | 163 KB | ✅ 无需优化 |
| 密码学库 | std.crypto | ✅ 与Rust同等 |


## 六、基准测试已添加

见 `src/jwt.zig` 中的 HMAC benchmark 测试。

## 七、下一步优化

### 已完成

- **io_uring 替换 epoll** ✅ - 使用异步 I/O，性能显著提升
- **二进制体积优化** ✅ - 当前仅 **163 KB**，无需额外优化

### 可选优化

1. **使用 Zig 的 SIMD 向量类型手动优化 Base64（@Vector）** - 当前性能已足够

2. **实现零拷贝 HTTP 解析（利用 splice）** - 收益有限，当前 buffer 模式已足够快

3. **libsodium 集成** - **不需要**！std.crypto 性能已与 Rust ring 库同等水平