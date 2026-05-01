const std = @import("std");
const Allocator = std.mem.Allocator;

const RateLimitConfig = @import("sliding_window_rate_limiter.zig").RateLimitConfig;
const AsyncLogger = @import("async_logger.zig").AsyncLogger;
const LogLevel = @import("log_level.zig").LogLevel;

pub const MyErrors = error{ UnsupportedAddressFamily, InvalidListenAddress, MissingSecretKey, UnsupportedPlatform, EnvVarMissing };

pub var global_io: std.Io = undefined;
pub fn initGlobalIo(io: std.Io) void {
    global_io = io;
}

pub const MAX_PATH_LENGTH: usize = 2048;
pub const MAX_HEADER_LENGTH: usize = 8192;
pub const MAX_TOKEN_LENGTH: usize = 4096;
pub const MIN_SECRET_KEY_LENGTH: usize = 32;

pub const DEFAULT_LISTEN_ADDR = "0.0.0.0:9090";
pub const DEFAULT_HEADER_KEY = "Authorization";

pub const Stats align(64) = struct {
    total: u64 = 0,
    allowed: u64 = 0,
    blocked: u64 = 0,
    errors: u64 = 0,
    _padding: [32]u8 = undefined,
};

pub var global_log_level: LogLevel = .err;
pub var global_async_logger: ?*AsyncLogger = null;

pub fn log(level: LogLevel, comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) >= @intFromEnum(global_log_level)) {
        if (global_async_logger) |logger| {
            var buf: [256]u8 = undefined;
            const len = std.fmt.bufPrint(&buf, format, args) catch return;
            logger.log(level, buf[0..len]);
        } else {
            const prefix = switch (level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
            std.debug.print("[{s}] " ++ format ++ "\n", .{prefix} ++ args);
        }
    }
}

// ==========================================
// 配置结构（同前，保持不变）
// ==========================================

pub const AppConfig = struct {
    listen_addr: []const u8,
    secret_key: []const u8,
    header_key: []const u8,
    log_level: LogLevel = .err,
    io_cpu: ?u6 = null,
    whitelist: []const []const u8,
    blocked_paths: []const []const u8,
    rate_limits: []const RateLimitConfig,

    pub fn validate(self: *const AppConfig) MyErrors!void {
        if (self.secret_key.len < MIN_SECRET_KEY_LENGTH) log(.warn, "Secret key too short\n", .{});
        if (std.mem.indexOfScalar(u8, self.listen_addr, ':') == null) return error.InvalidListenAddress;
    }

    pub fn deinit(self: *AppConfig, allocator: Allocator) void {
        allocator.free(@constCast(self.listen_addr));
        allocator.free(@constCast(self.secret_key));
        allocator.free(@constCast(self.header_key));
        for (self.whitelist) |s| allocator.free(@constCast(s));
        allocator.free(@constCast(self.whitelist));
        for (self.blocked_paths) |s| allocator.free(@constCast(s));
        allocator.free(@constCast(self.blocked_paths));
        for (self.rate_limits) |rule| allocator.free(@constCast(rule.path_pattern));
        allocator.free(@constCast(self.rate_limits));
    }
};

pub const FileConfig = struct {
    server: ServerConfig = .{},
    jwt: JwtConfig = .{},
    whitelist: [][]const u8 = &.{},
    blocked_paths: [][]const u8 = &.{},
    rate_limits: []RateLimitConfig = &.{},
    log_level: LogLevel = .err,

    pub const ServerConfig = struct {
        listen_addr: []const u8 = DEFAULT_LISTEN_ADDR,
        log_level: LogLevel = .err,
        io_cpu: ?i32 = null,
    };
    pub const JwtConfig = struct { secret_key: []const u8 = "", header_key: []const u8 = DEFAULT_HEADER_KEY };

    pub fn validate(self: *const FileConfig) MyErrors!void {
        if (self.jwt.secret_key.len == 0) return error.MissingSecretKey;
        if (self.jwt.secret_key.len < MIN_SECRET_KEY_LENGTH) log(.warn, "Secret key too short\n", .{});
    }

    pub fn deinit(self: *FileConfig, allocator: Allocator) void {
        allocator.free(@constCast(self.server.listen_addr));
        allocator.free(@constCast(self.jwt.secret_key));
        allocator.free(@constCast(self.jwt.header_key));
        for (self.whitelist) |s| allocator.free(@constCast(s));
        allocator.free(self.whitelist);
        for (self.blocked_paths) |s| allocator.free(@constCast(s));
        allocator.free(self.blocked_paths);
        for (self.rate_limits) |rc| allocator.free(@constCast(rc.path_pattern));
        allocator.free(self.rate_limits);
    }
};

pub fn getPathFromRequest(buf: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, buf, "\r\n") orelse std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    const line = buf[0..end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    var rest = line[first_space + 1 ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const raw = rest[0..second_space];
    if (raw.len == 0) return null;
    if (raw.len > MAX_PATH_LENGTH) return null;
    const q_pos = std.mem.indexOfScalar(u8, raw, '?') orelse raw.len;
    return raw[0..q_pos];
}

pub fn loadConfigFromFile(allocator: Allocator, config_path: []const u8) !AppConfig {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(global_io, config_path, .{ .mode = .read_only });
    defer file.close(global_io);
    var file_buf: [1024 * 1024]u8 = undefined;
    const n = try file.readPositionalAll(global_io, &file_buf, 0);
    const content = file_buf[0..n];
    var parsed = try std.json.parseFromSlice(FileConfig, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const fc = parsed.value;

    const listen_addr = try allocator.dupe(u8, fc.server.listen_addr);
    errdefer allocator.free(@constCast(listen_addr));
    const secret_key = try allocator.dupe(u8, fc.jwt.secret_key);
    errdefer allocator.free(@constCast(secret_key));
    const header_key = try allocator.dupe(u8, fc.jwt.header_key);
    errdefer allocator.free(@constCast(header_key));
    const whitelist = try dupeStrings(allocator, fc.whitelist);
    errdefer {
        for (whitelist) |s| allocator.free(@constCast(s));
        allocator.free(@constCast(whitelist));
    }
    const blocked_paths = try dupeStrings(allocator, fc.blocked_paths);
    errdefer {
        for (blocked_paths) |s| allocator.free(@constCast(s));
        allocator.free(@constCast(blocked_paths));
    }
    var rate_list = std.ArrayList(RateLimitConfig).empty;
    errdefer {
        for (rate_list.items) |rule| allocator.free(@constCast(rule.path_pattern));
        rate_list.deinit(allocator);
    }
    for (fc.rate_limits) |rc| {
        const pattern_dupe = try allocator.dupe(u8, rc.path_pattern);
        try rate_list.append(allocator, RateLimitConfig{
            .path_pattern = pattern_dupe,
            .qps = rc.qps,
            .burst = rc.burst,
            .window_seconds = rc.window_seconds,
            .user_qps = rc.user_qps,
            .user_burst = rc.user_burst,
        });
    }
    return AppConfig{
        .listen_addr = listen_addr,
        .secret_key = secret_key,
        .header_key = header_key,
        .log_level = fc.server.log_level,
        .io_cpu = if (fc.server.io_cpu) |c| @intCast(c) else null,
        .whitelist = whitelist,
        .blocked_paths = blocked_paths,
        .rate_limits = try rate_list.toOwnedSlice(allocator),
    };
}

fn dupeStrings(allocator: Allocator, list: []const []const u8) ![][]const u8 {
    const copy = try allocator.alloc([]const u8, list.len);
    errdefer {
        for (copy) |s| allocator.free(@constCast(s));
        allocator.free(copy);
    }
    for (list, 0..) |s, i| copy[i] = try allocator.dupe(u8, s);
    return copy;
}

// 测试（可选）
test "load config from file" {
    const allocator = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{});
    defer io_backend.deinit();
    initGlobalIo(io_backend.io());

    const src_path = @src().file;
    const src_dir = std.fs.path.dirname(src_path) orelse ".";
    const config_path = try std.fs.path.join(allocator, &.{ src_dir, "config.json" });
    defer allocator.free(config_path);
    var cfg = try loadConfigFromFile(allocator, config_path);
    defer cfg.deinit(allocator);
    std.debug.print("Config loaded successfully\n", .{});
}
