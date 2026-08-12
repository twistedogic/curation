// Bearer token authentication gate.
// ponytail: single shared token, single client; revisit if multi-client
// per-item tokens ever appear.
const std = @import("std");

/// Constant-time bearer token check.
/// `header_value` is the full Authorization header (e.g. "Bearer secret123").
/// Returns true iff the header is well-formed and the token matches `configured`.
pub fn checkBearer(header_value: []const u8, configured: []const u8) bool {
    const prefix = "Bearer ";
    if (header_value.len < prefix.len) return false;
    if (!std.mem.eql(u8, header_value[0..prefix.len], prefix)) return false;
    const token = header_value[prefix.len..];
    if (token.len != configured.len) return false;
    // ponytail: manual loop instead of crypto.utils.timingSafeEql because
    // timingSafeEql requires fixed-size arrays; length pre-check makes this
    // safe (same length → constant time over the equal-length compare).
    var acc: u8 = 0;
    for (token, configured) |a, b| acc |= a ^ b;
    return acc == 0;
}

test "auth: valid bearer accepted" {
    try std.testing.expect(checkBearer("Bearer secret-token-123", "secret-token-123"));
}

test "auth: wrong token rejected" {
    try std.testing.expect(!checkBearer("Bearer wrong-token", "secret-token-123"));
}

test "auth: missing header rejected" {
    try std.testing.expect(!checkBearer("", "secret-token-123"));
}

test "auth: wrong prefix rejected" {
    try std.testing.expect(!checkBearer("Basic secret-token-123", "secret-token-123"));
    try std.testing.expect(!checkBearer("secret-token-123", "secret-token-123"));
}

test "auth: length mismatch rejected" {
    try std.testing.expect(!checkBearer("Bearer short", "secret-token-123"));
    try std.testing.expect(!checkBearer("Bearer secret-token-123-extra", "secret-token-123"));
}

test "auth: case-sensitive prefix" {
    try std.testing.expect(!checkBearer("bearer secret-token-123", "secret-token-123"));
    try std.testing.expect(!checkBearer("BEARER secret-token-123", "secret-token-123"));
}
