const sws = @import("sws");
const handler = @import("handler.zig");

pub fn registerRoutes(server: *sws.AsyncServer) !void {
    try server.useThenRespondImmediately("/antpath-verify", handler.verifyMiddleware);
    try server.useThenRespondImmediately("/healthz", handler.healthMiddleware);
    try server.GET("/metrics", handler.handleMetrics);
}
