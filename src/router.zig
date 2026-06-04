const sws = @import("sws");
const handler = @import("handler.zig");

pub fn registerRoutes(server: *sws.AsyncServer) !void {
    // ⚠️ 必须使用 "/**" 全局匹配，绝对不能改成精确路径（如 /antpath-verify）。
    // 原因：Traefik forwardAuth 中间件会将原始客户端请求路径（如 /v1/user/public/token）
    // 追加到 forwardAuth 地址后面发送给本服务。如果这里用精确路径匹配，只有恰好等于
    // /antpath-verify 的请求才会被处理，其余所有请求都会走到 sws 默认 404，导致网关层
    // 所有经过 forwardAuth 的请求全部返回 404。
    // "/**" 注册为 global middleware（sws http_routing.zig:100-108），匹配所有路径。
    // 具体路径的白名单/黑名单/JWT 校验逻辑由 handler.verifyMiddleware 内部根据 config.json 决定。
    try server.useThenRespondImmediately("/**", handler.verifyMiddleware);

    // /healthz 和 /metrics 已在 config.json whitelist 中，会被 verifyMiddleware 放行。
    // 保留独立中间件作为双重保障，即使 whitelist 配置被误删也能保证健康检查可用。
    try server.useThenRespondImmediately("/healthz", handler.healthMiddleware);
    try server.useThenRespondImmediately("/metrics", handler.handleMetrics);
}
