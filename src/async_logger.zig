const std = @import("std");
const RingBuffer = @import("sws").RingBuffer;
const Thread = std.Thread;
const atomic = std.atomic;
const linux = std.os.linux;

const LogLevel = @import("log_level.zig").LogLevel;

const LOG_MSG_SIZE: usize = 256;

const LogEntry = struct {
    level: LogLevel,
    message: [LOG_MSG_SIZE]u8,
    len: usize,
};

pub const AsyncLogger = struct {
    const Self = @This();

    buffer: RingBuffer(LogEntry, 1024),
    thread: Thread,
    shutdown: atomic.Value(bool),
    started: bool,
    eventfd: i32,

    pub fn init() Self {
        const efd_raw = linux.eventfd(0, 0);
        return .{
            .buffer = RingBuffer(LogEntry, 1024).init(),
            .thread = undefined,
            .shutdown = atomic.Value(bool).init(false),
            .started = false,
            .eventfd = @intCast(efd_raw),
        };
    }

    pub fn start(self: *Self) !void {
        self.thread = try Thread.spawn(.{}, logThread, .{self});
        self.started = true;
    }

    pub fn stop(self: *Self) void {
        if (!self.started) return;
        self.shutdown.store(true, .release);
        const val: u64 = 1;
        _ = linux.write(self.eventfd, @as([*]const u8, @ptrCast(&val)), @sizeOf(u64));
        self.thread.join();
        _ = linux.close(self.eventfd);
    }

    pub fn log(self: *Self, level: LogLevel, msg: []const u8) void {
        if (!self.started) return;
        var entry = LogEntry{
            .level = level,
            .message = undefined,
            .len = 0,
        };
        const copy_len = @min(msg.len, LOG_MSG_SIZE);
        @memcpy(entry.message[0..copy_len], msg[0..copy_len]);
        entry.len = copy_len;
        _ = self.buffer.tryPush(entry);
        const val: u64 = 1;
        _ = linux.write(self.eventfd, @as([*]const u8, @ptrCast(&val)), @sizeOf(u64));
    }

    fn logThread(self: *Self) void {
        var pfds: [1]linux.pollfd = undefined;
        pfds[0] = .{ .fd = self.eventfd, .events = linux.POLL.IN, .revents = 0 };

        while (!self.shutdown.load(.acquire)) {
            while (self.buffer.tryPop()) |entry| {
                const level_str = switch (entry.level) {
                    .debug => "DEBUG",
                    .info => "INFO",
                    .warn => "WARN",
                    .err => "ERROR",
                };
                std.debug.print("[{s}] {s}\n", .{ level_str, entry.message[0..entry.len] });
            }
            _ = linux.poll(&pfds, pfds.len, -1);
            if (pfds[0].revents & linux.POLL.IN != 0) {
                var val: u64 = 0;
                _ = linux.read(self.eventfd, @as([*]u8, @ptrCast(&val)), @sizeOf(u64));
            }
        }

        while (self.buffer.tryPop()) |entry| {
            const level_str = switch (entry.level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
            std.debug.print("[{s}] {s}\n", .{ level_str, entry.message[0..entry.len] });
        }
    }
};

test "async logger basic" {
    var logger = AsyncLogger.init();
    try logger.start();
    logger.log(LogLevel.info, "test message");
    logger.log(LogLevel.err, "error message");
    // stop() 会等待线程结束并处理所有剩余日志，无需额外 sleep
    logger.stop();
}

test "async logger queue overflow" {
    var logger = AsyncLogger.init();
    try logger.start();
    // 发送比缓冲区容量更多的消息（缓冲区大小 1024）
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        logger.log(LogLevel.info, "message");
    }
    logger.stop();
}
