const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const JWT_CLOCK_SKEW_SECONDS: i64 = 60;

pub fn currentTimestampSec(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    return now.toSeconds();
}

pub const Payload = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Payload) void {
        self.parsed.deinit();
    }
};

pub const VerifyResult = struct {
    valid: bool,
    payload: ?*Payload,
    error_msg: []const u8,
};

pub fn verifyHmac(token: []const u8, secret: []const u8, allocator: Allocator, io: std.Io) VerifyResult {
    if (token.len == 0) return .{ .valid = false, .payload = null, .error_msg = "Empty token" };

    // 1. 分割 JWT
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |p| {
        if (count >= 3) return .{ .valid = false, .payload = null, .error_msg = "JWT data incomplete" };
        parts[count] = p;
        count += 1;
    }
    if (count != 3) return .{ .valid = false, .payload = null, .error_msg = "JWT data incomplete" };

    // 2. 验证签名
    const sig_start = parts[0].len + 1 + parts[1].len;
    const signing_input = token[0..sig_start];

    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, signing_input, secret);

    var sig_decoded: [32]u8 = undefined;
    const sig_len = std.base64.url_safe_no_pad.decoderWithIgnore("").decode(&sig_decoded, parts[2]) catch {
        return .{ .valid = false, .payload = null, .error_msg = "Invalid base64 in signature" };
    };
    if (sig_len != mac.len or !std.crypto.timing_safe.eql([32]u8, mac, sig_decoded)) {
        return .{ .valid = false, .payload = null, .error_msg = "Invalid signature" };
    }

    // 3. 解码 payload
    var pay_buf: [4096]u8 = undefined;
    const pay_decode = std.base64.url_safe_no_pad.decoderWithIgnore("");
    const pay_len = pay_decode.decode(&pay_buf, parts[1]) catch {
        return .{ .valid = false, .payload = null, .error_msg = "Invalid base64 in payload" };
    };
    const pay = pay_buf[0..pay_len];

    // 4. 解析 JSON
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, pay, .{}) catch {
        return .{ .valid = false, .payload = null, .error_msg = "Invalid JSON payload" };
    };
    errdefer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .valid = false, .payload = null, .error_msg = "JWT data incomplete" };
    }

    // 5. 时间检查
    const now_sec = currentTimestampSec(io);

    // 检查 exp
    if (parsed.value.object.get("exp")) |v| {
        const exp = if (v == .integer) v.integer else null orelse {
            return .{ .valid = false, .payload = null, .error_msg = "Invalid exp field" };
        };
        if (now_sec > exp + JWT_CLOCK_SKEW_SECONDS) {
            return .{ .valid = false, .payload = null, .error_msg = "Token expired" };
        }
    }

    if (parsed.value.object.get("nbf")) |v| {
        const nbf = if (v == .integer) v.integer else null orelse {
            return .{ .valid = false, .payload = null, .error_msg = "Invalid nbf field" };
        };
        if (now_sec < nbf - JWT_CLOCK_SKEW_SECONDS) {
            return .{ .valid = false, .payload = null, .error_msg = "Token not yet valid" };
        }
    }

    // 6. 转移所有权
    const payload = allocator.create(Payload) catch {
        parsed.deinit();
        return .{ .valid = false, .payload = null, .error_msg = "Out of memory" };
    };
    payload.* = .{ .parsed = parsed };
    return .{ .valid = true, .payload = payload, .error_msg = "" };
}
