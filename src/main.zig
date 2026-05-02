const std = @import("std");
const Allocator = std.mem.Allocator;

const swas = @import("swas");
const RateLimiter = @import("sliding_window_rate_limiter.zig").RateLimiter;
const PrometheusMetrics = @import("prometheus_metrics.zig").PrometheusMetrics;
const AsyncLogger = @import("async_logger.zig").AsyncLogger;
const app = @import("app.zig");
const router = @import("router.zig");
const handler = @import("handler.zig");

const MyErrors = app.MyErrors;

// ==========================================
// 主函数与启动逻辑
// ==========================================

const EnvConfig = struct {
    config_path: ?[]const u8,
    secret_key: ?[]const u8,
};

fn loadEnvConfig(env_map: *std.process.Environ.Map, allocator: Allocator) !EnvConfig {
    return .{
        .config_path = if (env_map.get("CONFIG_PATH")) |v| try allocator.dupe(u8, v) else null,
        .secret_key = if (env_map.get("JWT_SECRET_KEY")) |v| try allocator.dupe(u8, v) else null,
    };
}

pub fn main(init: std.process.Init) MyErrors!void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    const alloc: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    for (args) |arg| {
        app.log(.info, "arg: {s}", .{arg});
    }

    const io_backend = init.io;
    app.initGlobalIo(io_backend);

    const async_logger = try alloc.create(AsyncLogger);
    errdefer {
        app.global_async_logger = null;
        alloc.destroy(async_logger);
    }
    async_logger.* = AsyncLogger.init();
    app.global_async_logger = async_logger;

    var stats: app.Stats = .{};

    const env_cfg = try loadEnvConfig(init.environ_map, alloc);
    defer {
        if (env_cfg.config_path) |p| alloc.free(p);
        if (env_cfg.secret_key) |s| alloc.free(s);
    }

    const config_path = env_cfg.config_path orelse "config.json";

    const app_cfg = if (app.loadConfigFromFile(alloc, config_path)) |cfg| blk: {
        cfg.validate() catch |err| {
            app.log(.err, "Config validation failed: {s}\n", .{@errorName(err)});
            cfg.deinit(alloc);
            return err;
        };
        break :blk cfg;
    } else |_| blk: {
        app.log(.warn, "Load config failed, use env JWT_SECRET_KEY\n", .{});
        const secret_key = env_cfg.secret_key orelse {
            app.log(.err, "No JWT_SECRET_KEY env set and no config.json\n", .{});
            return error.MissingSecretKey;
        };
        var default_cfg = app.AppConfig{
            .listen_addr = try alloc.dupe(u8, app.DEFAULT_LISTEN_ADDR),
            .secret_key = try alloc.dupe(u8, secret_key),
            .header_key = try alloc.dupe(u8, app.DEFAULT_HEADER_KEY),
            .whitelist = &.{},
            .blocked_paths = &.{},
            .rate_limits = &.{},
        };
        errdefer default_cfg.deinit(alloc);
        default_cfg.validate() catch |err| {
            app.log(.err, "Default config validation failed: {s}\n", .{@errorName(err)});
            default_cfg.deinit(alloc);
            return err;
        };
        break :blk default_cfg;
    };
    defer app_cfg.deinit(alloc);
    app.global_log_level = app_cfg.log_level;
    try startServer(alloc, app_cfg, &stats, async_logger);
}

fn startServer(alloc: Allocator, cfg: app.AppConfig, stats: *app.Stats, async_logger: *app.AsyncLogger) MyErrors!void {
    try async_logger.start();
    defer async_logger.stop();

    std.debug.print("🚀 JWT Gateway with io_uring on {s}\n", .{cfg.listen_addr});

    // 构建 whitelist 规则
    var wl_list = std.ArrayList(swas.PathRule).empty;
    defer {
        for (wl_list.items) |*r| r.deinit();
        wl_list.deinit(alloc);
    }
    for (cfg.whitelist) |p| try wl_list.append(alloc, try swas.PathRule.init(alloc, p));
    const wl_rules = try wl_list.toOwnedSlice(alloc);
    errdefer {
        for (wl_rules) |*r| r.deinit();
        alloc.free(wl_rules);
    }

    // 构建 blocked 规则
    var bl_list = std.ArrayList(swas.PathRule).empty;
    defer {
        for (bl_list.items) |*r| r.deinit();
        bl_list.deinit(alloc);
    }
    for (cfg.blocked_paths) |p| try bl_list.append(alloc, try swas.PathRule.init(alloc, p));
    const bl_rules = try bl_list.toOwnedSlice(alloc);
    errdefer {
        for (bl_rules) |*r| r.deinit();
        alloc.free(bl_rules);
    }

    // 初始化限流器
    var rl_ptr: ?*RateLimiter = null;
    if (cfg.rate_limits.len > 0) {
        const ptr = try alloc.create(RateLimiter);
        errdefer alloc.destroy(ptr);
        ptr.* = try RateLimiter.init(alloc, cfg.rate_limits, app.global_io);
        rl_ptr = ptr;
    }
    defer if (rl_ptr) |rl| {
        rl.deinit();
        alloc.destroy(rl);
    };

    // 创建 metrics
    var metrics = try alloc.create(PrometheusMetrics);
    metrics.* = PrometheusMetrics.init(alloc);
    defer {
        metrics.deinit();
        alloc.destroy(metrics);
    }

    // 构建业务上下文
    var ctx = handler.JwtContext{
        .allocator = alloc,
        .config = cfg,
        .stats = stats,
        .metrics = metrics,
        .rate_limiter = rl_ptr,
        .wl_rules = wl_rules,
        .bl_rules = bl_rules,
    };

    // 创建异步服务器，传递上下文
    var server = try swas.AsyncServer.init(alloc, app.global_io, cfg.listen_addr, &ctx);
    defer server.deinit();

    server.config(.max_path_length, app.MAX_PATH_LENGTH);
    if (cfg.io_cpu) |cpu| server.config(.io_cpu, cpu);
    try router.registerRoutes(&server);

    // 运行服务器
    try server.run();
}
