const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_backend = std.Io.Threaded.init(allocator, .{});
    defer io_backend.deinit();
    const io = io_backend.io();

    const now = std.Io.Clock.real.now(io);
    const ms = @divTrunc(now.nanoseconds, @as(i96, 1_000_000));
    std.debug.print("Current timestamp (ms): {}\n", .{ms});
}
