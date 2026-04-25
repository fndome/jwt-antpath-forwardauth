const std = @import("std");

pub const MetricType = enum { counter, gauge };

pub const Metric = union(MetricType) {
    counter: u64,
    gauge: f64,
};

pub const PrometheusMetrics = struct {
    allocator: std.mem.Allocator,
    metrics: std.StringHashMap(Metric),

    pub fn init(allocator: std.mem.Allocator) PrometheusMetrics {
        return .{
            .allocator = allocator,
            .metrics = std.StringHashMap(Metric).init(allocator),
        };
    }

    pub fn deinit(self: *PrometheusMetrics) void {
        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.metrics.deinit();
    }

    pub fn incCounter(self: *PrometheusMetrics, name: []const u8, labels: ?[]const u8) !void {
        const key = try self.makeKey(name, labels);
        errdefer self.allocator.free(key);

        const entry = try self.metrics.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.counter += 1;
        } else {
            entry.value_ptr.* = .{ .counter = 1 };
        }
    }

    pub fn setGauge(self: *PrometheusMetrics, name: []const u8, value: f64, labels: ?[]const u8) !void {
        const key = try self.makeKey(name, labels);
        errdefer self.allocator.free(key);

        const entry = try self.metrics.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.gauge = value;
        } else {
            entry.value_ptr.* = .{ .gauge = value };
        }
    }

    pub fn addGauge(self: *PrometheusMetrics, name: []const u8, delta: f64, labels: ?[]const u8) !void {
        const key = try self.makeKey(name, labels);
        errdefer self.allocator.free(key);

        const entry = try self.metrics.getOrPut(key);
        if (entry.found_existing) {
            self.allocator.free(key);
            entry.value_ptr.gauge += delta;
        } else {
            entry.value_ptr.* = .{ .gauge = delta };
        }
    }

    fn makeKey(self: *PrometheusMetrics, name: []const u8, labels: ?[]const u8) ![]u8 {
        if (labels) |l| {
            return try std.fmt.allocPrint(self.allocator, "{s}{{{s}}}", .{ name, l });
        }
        return try self.allocator.dupe(u8, name);
    }

    pub fn collect(self: *PrometheusMetrics, writer: *std.Io.Writer) !void {
        var type_emitted = std.StringHashMap(void).init(self.allocator);
        defer type_emitted.deinit();

        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const metric = entry.value_ptr.*;

            const metric_name = if (std.mem.indexOfScalar(u8, key, '{')) |brace|
                key[0..brace]
            else
                key;

            if (!type_emitted.contains(metric_name)) {
                try type_emitted.put(metric_name, {});
                try writer.print("# TYPE {s} {s}\n", .{ metric_name, @tagName(metric) });
            }

            try writer.print("{s} ", .{key});
            switch (metric) {
                .counter => try writer.print("{d}\n", .{metric.counter}),
                .gauge => try writer.print("{d:.6}\n", .{metric.gauge}),
            }
        }
    }
};

// ======================== 测试 ========================
test "counter increments" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    try metrics.incCounter("http_requests", null);
    try metrics.incCounter("http_requests", null);
    try metrics.incCounter("http_requests", null);

    var buffer: [4096]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(buffer[0..]);
    try metrics.collect(&fixed_writer); // 传递指针

    const end = fixed_writer.end;
    const output = buffer[0..end];
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE http_requests counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "http_requests 3\n") != null);
}

test "gauge set and add" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    try metrics.setGauge("temperature", 23.5, null);
    try metrics.addGauge("temperature", 1.2, null);
    try metrics.addGauge("temperature", -0.7, null);

    var buffer: [4096]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(buffer[0..]);
    try metrics.collect(&fixed_writer);

    const end = fixed_writer.end;
    const output = buffer[0..end];
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE temperature gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "temperature 24.000000\n") != null);
}

test "labels" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    try metrics.incCounter("requests", "method=GET,status=200");
    try metrics.incCounter("requests", "method=GET,status=200");
    try metrics.incCounter("requests", "method=POST,status=200");
    try metrics.incCounter("requests", "method=GET,status=500");

    var buffer: [4096]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(buffer[0..]);
    try metrics.collect(&fixed_writer);

    const end = fixed_writer.end;
    const output = buffer[0..end];
    try std.testing.expect(std.mem.indexOf(u8, output, "requests{method=GET,status=200} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "requests{method=POST,status=200} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "requests{method=GET,status=500} 1\n") != null);
}

test "memory leak detection" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var metrics = PrometheusMetrics.init(allocator);
    try metrics.incCounter("test", null);
    try metrics.setGauge("temp", 42.0, null);
    metrics.deinit();
}
