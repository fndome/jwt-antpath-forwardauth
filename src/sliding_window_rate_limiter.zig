const std = @import("std");
const PathRule = @import("sws").PathRule;

pub const RateLimitConfig = struct {
    path_pattern: []const u8,
    qps: u32,
    burst: u32 = 0,
    window_seconds: u32 = 1,
    user_qps: u32 = 0,
    user_burst: u32 = 0,
};

pub const RateLimitResult = struct {
    allowed: bool,
    limit: u32,
    remaining: u32,
};

fn nowMs(io: std.Io) !i64 {
    const now = std.Io.Clock.real.now(io);
    return now.toMilliseconds();
}

const UserState = struct {
    count: u32,
    window_start: i64, // 毫秒
};

const SlidingWindowLimiter = struct {
    rule: PathRule,
    max_requests: usize,
    window_ms: i64,
    sub_windows: usize,
    counts: []usize,
    timestamps: []i64,
    sub_window_ms: i64,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, rule: PathRule, max_requests: usize, window_seconds: i64, io: std.Io) !SlidingWindowLimiter {
        const sub_windows: usize = 10;
        const window_ms = window_seconds * 1000;
        const sub_window_ms = @divTrunc(window_ms, sub_windows);
        if (sub_window_ms == 0) return error.WindowTooSmall;

        const counts = try allocator.alloc(usize, sub_windows);
        errdefer allocator.free(counts);
        const timestamps = try allocator.alloc(i64, sub_windows);
        errdefer allocator.free(timestamps);

        @memset(counts, 0);
        @memset(timestamps, 0);

        return .{
            .rule = rule,
            .max_requests = max_requests,
            .window_ms = window_ms,
            .sub_windows = sub_windows,
            .counts = counts,
            .timestamps = timestamps,
            .sub_window_ms = sub_window_ms,
            .io = io,
        };
    }

    pub fn deinit(self: *SlidingWindowLimiter, allocator: std.mem.Allocator) void {
        allocator.free(self.counts);
        allocator.free(self.timestamps);
        self.rule.deinit();
    }

    pub fn allowRequest(self: *SlidingWindowLimiter) bool {
        const now_ms = nowMs(self.io) catch return false; // 时间获取失败则拒绝（保守）
        const window_start = now_ms - self.window_ms;

        const ms = @max(0, now_ms);
        const idx_i64 = @mod(@divTrunc(ms, self.sub_window_ms), @as(i64, @intCast(self.sub_windows)));
        const sub_idx = @as(usize, @intCast(idx_i64));

        if (self.timestamps[sub_idx] < window_start) {
            self.counts[sub_idx] = 0;
            self.timestamps[sub_idx] = now_ms;
        }

        var total: usize = 0;
        for (self.timestamps, 0..) |ts, i| {
            if (ts >= window_start) {
                total += self.counts[i];
            }
        }

        if (total >= self.max_requests) return false;

        self.counts[sub_idx] += 1;
        return true;
    }
};

pub const RateLimiter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    limiters: []SlidingWindowLimiter,
    user_limit_cfg: []u32,
    user_burst_cfg: []u32,
    user_states: []std.AutoHashMap(u64, UserState),
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, rules: []const RateLimitConfig, io: std.Io) !Self {
        var limiters = try allocator.alloc(SlidingWindowLimiter, rules.len);
        errdefer allocator.free(limiters);
        var user_limit_cfg = try allocator.alloc(u32, rules.len);
        errdefer allocator.free(user_limit_cfg);
        var user_burst_cfg = try allocator.alloc(u32, rules.len);
        errdefer allocator.free(user_burst_cfg);
        var user_states = try allocator.alloc(std.AutoHashMap(u64, UserState), rules.len);
        errdefer {
            for (user_states) |*map| map.deinit();
            allocator.free(user_states);
        }

        for (rules, 0..) |rule, i| {
            const path_rule = try PathRule.init(allocator, rule.path_pattern);
            const max_requests = if (rule.burst > 0) rule.burst else rule.qps;
            limiters[i] = try SlidingWindowLimiter.init(allocator, path_rule, max_requests, @as(i64, rule.window_seconds), io);
            user_limit_cfg[i] = rule.user_qps;
            user_burst_cfg[i] = if (rule.user_burst > 0) rule.user_burst else rule.user_qps;
            user_states[i] = std.AutoHashMap(u64, UserState).init(allocator);
        }

        return Self{
            .allocator = allocator,
            .limiters = limiters,
            .user_limit_cfg = user_limit_cfg,
            .user_burst_cfg = user_burst_cfg,
            .user_states = user_states,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.limiters) |*lim| {
            lim.deinit(self.allocator);
        }
        self.allocator.free(self.limiters);
        self.allocator.free(self.user_limit_cfg);
        self.allocator.free(self.user_burst_cfg);
        for (self.user_states) |*map| {
            map.deinit();
        }
        self.allocator.free(self.user_states);
    }

    pub fn allowUserRequest(self: *Self, user_id: []const u8, path: []const u8) RateLimitResult {
        var rule_idx: ?usize = null;
        for (self.limiters, 0..) |*lim, idx| {
            if (lim.rule.match(path)) {
                rule_idx = idx;
                break;
            }
        }
        if (rule_idx == null) {
            return .{ .allowed = true, .limit = 0, .remaining = 0 };
        }
        const idx = rule_idx.?;
        const lim = &self.limiters[idx];

        const global_allowed = lim.allowRequest();
        const global_limit: u32 = @intCast(lim.max_requests);
        if (!global_allowed) {
            return .{ .allowed = false, .limit = global_limit, .remaining = 0 };
        }

        if (user_id.len == 0) {
            return .{ .allowed = true, .limit = global_limit, .remaining = global_limit - 1 };
        }

        const user_qps = self.user_limit_cfg[idx];
        if (user_qps == 0) {
            return .{ .allowed = true, .limit = global_limit, .remaining = global_limit - 1 };
        }

        const user_burst = self.user_burst_cfg[idx];
        const user_max = if (user_burst > 0) user_burst else user_qps;

        const user_key = std.hash.Wyhash.hash(0, user_id);
        const now_ms = nowMs(self.io) catch return .{ .allowed = false, .limit = user_max, .remaining = 0 };
        const map = &self.user_states[idx];

        const entry = map.getOrPut(user_key) catch {
            return .{ .allowed = false, .limit = user_max, .remaining = 0 };
        };

        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .count = 1, .window_start = now_ms };
            return .{ .allowed = true, .limit = user_max, .remaining = user_max - 1 };
        }

        var state = entry.value_ptr;
        const window_ms = lim.window_ms;
        if (now_ms - state.window_start >= window_ms) {
            state.count = 1;
            state.window_start = now_ms;
            return .{ .allowed = true, .limit = user_max, .remaining = user_max - 1 };
        } else {
            if (state.count >= user_max) {
                return .{ .allowed = false, .limit = user_max, .remaining = 0 };
            }
            state.count += 1;
            return .{ .allowed = true, .limit = user_max, .remaining = user_max - state.count };
        }
    }
};

test "RateLimiter with user-level limit" {
    const allocator = std.testing.allocator;
    const rules = &[_]RateLimitConfig{
        .{
            .path_pattern = "/**",
            .qps = 10,
            .window_seconds = 1,
            .user_qps = 2,
        },
    };

    // 测试需要创建一个 I/O 后端
    var io_backend = std.Io.Threaded.init(allocator, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    var limiter = try RateLimiter.init(allocator, rules, io);
    defer limiter.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const result = limiter.allowUserRequest("user123", "/api/v1/test");
        if (i < 2) {
            try std.testing.expect(result.allowed);
        } else {
            try std.testing.expect(!result.allowed);
        }
    }

    const result2 = limiter.allowUserRequest("user456", "/api/v1/test");
    try std.testing.expect(result2.allowed);
}

test "rate limiter test" {
    const alloc = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(alloc, .{});
    defer io_backend.deinit();
    const io = io_backend.io();
    var limiter = try RateLimiter.init(alloc, &.{}, io);
    defer limiter.deinit();
    _ = limiter.allowUserRequest("test", "/");
}
