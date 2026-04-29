const std = @import("std");
const Allocator = std.mem.Allocator;

const PathRule = @import("swas").PathRule;
const Context = @import("swas").Context;
const jwt = @import("jwt.zig");
const app = @import("app.zig");
const ratelimiter = @import("sliding_window_rate_limiter.zig");
const metrics = @import("prometheus_metrics.zig");

// ==========================================
// 业务上下文 JwtContext
// ==========================================

const JwtContext = struct {
    allocator: Allocator,
    config: app.AppConfig,
    stats: *app.Stats,
    metrics: *metrics.PrometheusMetrics,
    rate_limiter: ?*ratelimiter.RateLimiter,
    wl_rules: []PathRule,
    bl_rules: []PathRule,
};

// ==========================================
// 路由处理函数
// ==========================================
pub fn verifyMiddleware(allocator: Allocator, c: *Context) anyerror!bool {
    _ = allocator;
    const srv_ctx = @as(*JwtContext, @ptrCast(@alignCast(c.app_ctx.?)));
    const content = c.request_data;

    if (content.len > app.MAX_HEADER_LENGTH) {
        srv_ctx.stats.total += 1;
        srv_ctx.stats.blocked += 1;
        try c.text(431, "Request Header Fields Too Large");
        return true;
    }

    const path = app.getPathFromRequest(content) orelse {
        srv_ctx.stats.total += 1;
        srv_ctx.stats.blocked += 1;
        try c.text(400, "Bad Request");
        return true;
    };

    srv_ctx.stats.total += 1;
    srv_ctx.metrics.incCounter("jwt_requests_total", null) catch {};

    if (matchesAny(path, srv_ctx.bl_rules)) {
        srv_ctx.stats.blocked += 1;
        srv_ctx.metrics.incCounter("jwt_blocked_total", null) catch {};
        try c.text(403, "Forbidden");
        return true;
    }

    if (matchesAny(path, srv_ctx.wl_rules)) {
        srv_ctx.stats.allowed += 1;
        srv_ctx.metrics.incCounter("jwt_whitelisted_total", null) catch {};
        return true;
    }

    const token = extractToken(content, srv_ctx.config.header_key) orelse {
        srv_ctx.stats.blocked += 1;
        srv_ctx.metrics.incCounter("jwt_blocked_total", null) catch {};
        try c.text(401, "Unauthorized");
        return true;
    };
    if (token.len == 0) {
        srv_ctx.stats.blocked += 1;
        srv_ctx.metrics.incCounter("jwt_blocked_total", null) catch {};
        try c.text(400, "Empty Token");
        return true;
    }

    const res = jwt.verifyHmac(token, srv_ctx.config.secret_key, srv_ctx.allocator, app.global_io);
    if (!res.valid) {
        srv_ctx.stats.blocked += 1;
        srv_ctx.metrics.incCounter("jwt_blocked_total", null) catch {};
        if (std.mem.eql(u8, res.error_msg, "Invalid signature")) {
            srv_ctx.metrics.incCounter("jwt_invalid_signatures_total", null) catch {};
        } else if (std.mem.eql(u8, res.error_msg, "Token expired")) {
            srv_ctx.metrics.incCounter("jwt_expired_tokens_total", null) catch {};
        }
        const status: u16 = if (std.mem.eql(u8, res.error_msg, "JWT data incomplete")) 400 else 401;
        try c.text(status, res.error_msg);
        return true;
    }
    const payload = res.payload orelse {
        srv_ctx.stats.blocked += 1;
        try c.text(500, "Internal Server Error");
        return true;
    };
    defer {
        payload.deinit();
        srv_ctx.allocator.destroy(payload);
    }

    var rl_result: ?ratelimiter.RateLimitResult = null;
    if (srv_ctx.rate_limiter) |rl| {
        const user_id = extractUserIdForRateLimit(srv_ctx.allocator, content, payload);
        defer if (user_id) |u| srv_ctx.allocator.free(@constCast(u));
        rl_result = rl.allowUserRequest(user_id orelse "", path);
        if (!rl_result.?.allowed) {
            srv_ctx.stats.blocked += 1;
            srv_ctx.metrics.incCounter("jwt_ratelimit_rejected_total", null) catch {};
            try c.rawJson(429, "{\"error\":\"Too Many Requests\"}");
            return true;
        }
    }

    srv_ctx.stats.allowed += 1;
    srv_ctx.metrics.incCounter("jwt_allowed_total", null) catch {};

    const claims_headers = buildClaimsHeaders(srv_ctx.allocator, payload) catch |err| {
        app.log(.err, "buildClaimsHeaders error: {s}\n", .{@errorName(err)});
        srv_ctx.stats.errors += 1;
        try c.text(500, "Internal Server Error");
        return true;
    };
    defer srv_ctx.allocator.free(claims_headers);

    if (c.headers == null) c.headers = std.ArrayList(u8).empty;

    if (rl_result) |rl_res| {
        const limit_line = try std.fmt.allocPrint(srv_ctx.allocator, "X-RateLimit-Limit: {d}\r\nX-RateLimit-Remaining: {d}\r\n", .{ rl_res.limit, rl_res.remaining });
        defer srv_ctx.allocator.free(limit_line);
        try c.headers.?.appendSlice(srv_ctx.allocator, limit_line);
    }
    try c.headers.?.appendSlice(srv_ctx.allocator, claims_headers);

    // 不设 body → 框架自动返回 200 OK + headers
    return true;
}

pub fn healthMiddleware(allocator: Allocator, ctx: *Context) anyerror!bool {
    _ = allocator;
    try ctx.text(200, "OK");
    return true;
}

pub fn handleMetrics(allocator: Allocator, ctx: *Context) !void {
    _ = allocator;

    const jwtContext = @as(*JwtContext, @ptrCast(@alignCast(ctx.app_ctx.?)));
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(buf[0..]);
    try jwtContext.metrics.collect(&writer);
    try ctx.text(200, buf[0..writer.end]);
}

// 辅助函数（同前，略作修改以使用 ctx 中的分配器）
fn extractUserIdForRateLimit(allocator: Allocator, request_buf: []const u8, payload: *const jwt.Payload) ?[]const u8 {
    if (extractHeader(request_buf, "X-User-Id")) |val| return allocator.dupe(u8, val) catch null;
    if (extractHeader(request_buf, "User-Id")) |val| return allocator.dupe(u8, val) catch null;
    if (payload.parsed.value != .object) return null;
    const obj = payload.parsed.value.object;
    if (obj.get("sub")) |v| {
        if (v == .string) return allocator.dupe(u8, v.string) catch null;
    }
    if (obj.get("user_id")) |v| {
        if (v == .string) return allocator.dupe(u8, v.string) catch null;
    }
    return null;
}

fn extractHeader(buf: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, buf, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, key)) {
            const val_start = line[key.len..];
            const val = std.mem.trimLeft(u8, val_start, " \t:");
            return std.mem.trimRight(u8, val, " \t\r");
        }
    }
    return null;
}

fn matchesAny(path: []const u8, rules: []const PathRule) bool {
    for (rules) |*r| if (r.match(path)) return true;
    return false;
}

fn extractToken(buf: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, buf, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, key)) {
            const val = std.mem.trimLeft(u8, line[key.len..], " \t:");
            const token = if (std.mem.startsWith(u8, val, "Bearer ")) val[7..] else val;
            if (token.len > app.MAX_TOKEN_LENGTH) return null;
            return token;
        }
    }
    return null;
}

fn buildClaimsHeaders(allocator: Allocator, payload: *const jwt.Payload) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    const json = payload.parsed.value;
    if (json != .object) return try list.toOwnedSlice(allocator);
    const obj = json.object;
    for (obj.keys, obj.values) |key, value| {
        const header_value = switch (value) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .number => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .bool => |b| if (b) "true" else "false",
            .null => "",
            .array => |arr| if (arr.items.len > 0 and arr.items[0] == .string) arr.items[0].string else "",
            .object => "",
        };
        defer {
            if (value == .integer or value == .number) allocator.free(@constCast(header_value));
        }
        try list.appendSlice(allocator, key);
        try list.appendSlice(allocator, ": ");
        try list.appendSlice(allocator, header_value);
        try list.appendSlice(allocator, "\r\n");
    }
    return try list.toOwnedSlice(allocator);
}
