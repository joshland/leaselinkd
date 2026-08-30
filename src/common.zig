const std = @import("std");

pub const version = "2.0.0";
pub const LogLevel = enum(u8) { ERROR = 0, WARN = 1, INFO = 2, DEBUG = 3 };
var active_log_level: LogLevel = .INFO;

pub fn setLogLevel(value: []const u8) !void {
    active_log_level = if (std.ascii.eqlIgnoreCase(value, "ERROR")) .ERROR else if (std.ascii.eqlIgnoreCase(value, "WARN")) .WARN else if (std.ascii.eqlIgnoreCase(value, "INFO")) .INFO else if (std.ascii.eqlIgnoreCase(value, "DEBUG")) .DEBUG else return error.InvalidLogLevel;
}
pub fn logLevel() LogLevel {
    return active_log_level;
}
pub fn log(comptime level: LogLevel, comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) <= @intFromEnum(active_log_level)) std.debug.print("[{s}] " ++ format ++ "\n", .{@tagName(level)} ++ args);
}

pub const Lease = struct { hostname: []const u8, @"ip-address": []const u8, @"mac-address": []const u8 = "", @"valid-lifetime": []const u8 = "", @"subnet-id": []const u8 = "", @"query-interface": []const u8 = "" };
pub const Event = struct { event: []const u8, timestamp: i64 = 0, lease: Lease };

pub const LeaseOperation = enum { committed, renew, release, expire, decline, recover };
pub fn leaseOperation(event: []const u8) ?LeaseOperation {
    if (std.mem.eql(u8, event, "lease4_committed")) return .committed;
    if (std.mem.eql(u8, event, "leases4_committed")) return .committed;
    if (std.mem.eql(u8, event, "lease4_renew")) return .renew;
    if (std.mem.eql(u8, event, "lease4_release")) return .release;
    if (std.mem.eql(u8, event, "lease4_expire")) return .expire;
    if (std.mem.eql(u8, event, "lease4_decline")) return .decline;
    if (std.mem.eql(u8, event, "lease4_recover")) return .recover;
    return null;
}
pub fn isRemovalEvent(event: []const u8) bool {
    return switch (leaseOperation(event) orelse return false) {
        .release, .expire, .decline, .recover => true,
        else => false,
    };
}
pub fn validHostLabel(hostname: []const u8) bool {
    if (hostname.len == 0 or hostname.len > 63 or hostname[0] == '-' or hostname[hostname.len - 1] == '-') return false;
    for (hostname) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return true;
}
pub fn validUnboundIpv4(address: []const u8) bool {
    var parts = std.mem.splitScalar(u8, address, '.');
    var count: u8 = 0;
    var first: u16 = 0;
    while (parts.next()) |part| {
        if (count == 4 or part.len == 0 or part.len > 3) return false;
        var value: u16 = 0;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return false;
            value = value * 10 + (ch - '0');
            if (value > 255) return false;
        }
        if (count == 0) first = value;
        count += 1;
    }
    return count == 4 and first != 127;
}
pub fn jsonEscape(writer: anytype, value: []const u8) !void {
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (ch < 0x20) try writer.print("\\u00{x:0>2}", .{ch}) else try writer.writeByte(ch),
    };
}
test "hostname validation" {
    try std.testing.expect(validHostLabel("workstation-7"));
    try std.testing.expect(!validHostLabel("bad name"));
}
test "Unbound IPv4 validation" {
    try std.testing.expect(validUnboundIpv4("10.111.1.1"));
    try std.testing.expect(!validUnboundIpv4("127.0.0.1"));
    try std.testing.expect(!validUnboundIpv4("300.1.1.1"));
    try std.testing.expect(!validUnboundIpv4("10.1.1"));
}
test "log level parser" {
    try setLogLevel("debug");
    try std.testing.expectEqual(LogLevel.DEBUG, logLevel());
    try std.testing.expectError(error.InvalidLogLevel, setLogLevel("verbose"));
}
