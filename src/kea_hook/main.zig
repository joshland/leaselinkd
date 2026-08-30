const std = @import("std");
const common = @import("common");
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const HookConfig = struct { leaselinkd_address: []const u8 = "unix:///run/leaselinkd/fifo.pipe", timeout_seconds: i64 = 2, loglevel: ?[]const u8 = null };
const CommandOptions = struct { event: []const u8, config_path: ?[]const u8 = null, loglevel_set: bool = false };
const Deadline = struct {
    at_ms: i64,
    fn init(timeout_seconds: i64) Deadline {
        return .{ .at_ms = monotonicMilliseconds() + timeout_seconds * 1000 };
    }
    fn remainingMs(self: Deadline) !c_int {
        const remaining = self.at_ms - monotonicMilliseconds();
        if (remaining <= 0) return error.ManagerTimeout;
        return @intCast(@min(remaining, @as(i64, std.math.maxInt(c_int))));
    }
};

pub fn main(init: std.process.Init) !void {
    const started_at = monotonicMilliseconds();
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = parseCommand(args) catch |err| {
        common.log(.ERROR, "invalid hook command line: {t}", .{err});
        return err;
    } orelse {
        try printHelp(init);
        return;
    };
    const config = loadConfig(init, allocator, options.config_path) catch |err| {
        common.log(.ERROR, "cannot load hook configuration: {t}", .{err});
        return err;
    };
    if (!options.loglevel_set) if (config.loglevel) |level| common.setLogLevel(level) catch |err| {
        common.log(.ERROR, "cannot use hook loglevel from configuration: {t}", .{err});
        return err;
    };
    common.log(.INFO, "kea-leaselink v{s} starting; loglevel={s}", .{ common.version, @tagName(common.logLevel()) });
    common.log(.DEBUG, "hook invocation: argv={any}; lease operation={s}; config_override={s}", .{ args, options.event, options.config_path orelse "(default)" });
    const operation = common.leaseOperation(options.event) orelse {
        common.log(.ERROR, "cannot forward unknown Kea hook point: {s}", .{options.event});
        return error.UnsupportedLeaseOperation;
    };
    common.log(.INFO, "Kea hook point received: {s} (operation={s})", .{ options.event, @tagName(operation) });
    const env = init.minimal.environ;
    if (std.mem.eql(u8, options.event, "leases4_committed")) return forwardCommittedBatch(init, allocator, options, started_at);
    const hostname = envValue(env, "KEA_LEASE4_HOSTNAME", "LEASE4_HOSTNAME") orelse {
        if (operation == .renew) {
            common.log(.INFO, "hostname-less lease4_renew deferred; awaiting leases4_committed authoritative lease data", .{});
            return;
        }
        common.log(.ERROR, "cannot forward event={s}: KEA_LEASE4_HOSTNAME is missing", .{options.event});
        return error.MissingLeaseHostname;
    };
    const ip = envValue(env, "KEA_LEASE4_ADDRESS", "LEASE4_ADDRESS") orelse {
        common.log(.ERROR, "cannot forward event={s}: KEA_LEASE4_ADDRESS is missing", .{options.event});
        return error.MissingLeaseAddress;
    };
    const mac = envValue(env, "KEA_LEASE4_HWADDR", "LEASE4_HWADDR") orelse "";
    const valid_lifetime = envValue(env, "KEA_LEASE4_VALID_LIFETIME", "LEASE4_VALID_LIFETIME") orelse "";
    const subnet_id = envValue(env, "KEA_LEASE4_SUBNET_ID", "LEASE4_SUBNET_ID") orelse "";
    const query_interface = envValue(env, "KEA_QUERY4_INTERFACE", "QUERY4_IFACE_NAME") orelse "";
    if (!common.validHostLabel(hostname)) {
        common.log(.ERROR, "cannot forward event={s}: invalid hostname={s}", .{ options.event, hostname });
        return error.InvalidLeaseHostname;
    }
    if (!common.isRemovalEvent(options.event) and !common.validUnboundIpv4(ip)) {
        common.log(.WARN, "invalid or loopback IPv4 lease address for event={s}: {s}", .{ options.event, ip });
        common.log(.ERROR, "cannot forward event={s}: invalid lease address", .{options.event});
        return error.InvalidLeaseAddress;
    }
    common.log(.INFO, "lease operation={s} host={s} ip={s}", .{ options.event, hostname, ip });
    common.log(.DEBUG, "Kea lease parameters: KEA_LEASE4_HOSTNAME={s}; KEA_LEASE4_ADDRESS={s}; KEA_LEASE4_HWADDR={s}; KEA_LEASE4_VALID_LIFETIME={s}; KEA_LEASE4_SUBNET_ID={s}; KEA_QUERY4_INTERFACE={s}; operation={s}", .{ hostname, ip, mac, valid_lifetime, subnet_id, query_interface, options.event });
    if (config.timeout_seconds <= 0 or config.timeout_seconds > 3600) {
        common.log(.ERROR, "cannot forward event={s}: invalid manager timeout={d}s", .{ options.event, config.timeout_seconds });
        return error.InvalidTimeout;
    }
    common.log(.DEBUG, "hook configuration: loglevel={s}; manager={s}; timeout={d}s", .{ @tagName(common.logLevel()), config.leaselinkd_address, config.timeout_seconds });
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"event\":\"");
    try common.jsonEscape(&body.writer, options.event);
    try body.writer.writeAll("\",\"timestamp\":0,\"lease\":{\"hostname\":\"");
    try common.jsonEscape(&body.writer, hostname);
    try body.writer.writeAll("\",\"ip-address\":\"");
    try common.jsonEscape(&body.writer, ip);
    try body.writer.writeAll("\",\"mac-address\":\"");
    try common.jsonEscape(&body.writer, mac);
    try body.writer.writeAll("\",\"valid-lifetime\":\"");
    try common.jsonEscape(&body.writer, valid_lifetime);
    try body.writer.writeAll("\",\"subnet-id\":\"");
    try common.jsonEscape(&body.writer, subnet_id);
    try body.writer.writeAll("\",\"query-interface\":\"");
    try common.jsonEscape(&body.writer, query_interface);
    try body.writer.writeAll("\"}}");
    common.log(.DEBUG, "forwarding payload: {s}", .{body.written()});
    const call_started_at = monotonicMilliseconds();
    post(config.leaselinkd_address, body.written(), Deadline.init(config.timeout_seconds)) catch |err| {
        const call_ms = monotonicMilliseconds() - call_started_at;
        const total_ms = monotonicMilliseconds() - started_at;
        common.log(.WARN, "manager transmission warning: event={s} result=failed error={t} call_ms={d}", .{ options.event, err, call_ms });
        common.log(.ERROR, "lease operation failed: event={s} manager_api=failed total_ms={d}", .{ options.event, total_ms });
        return err;
    };
    const call_ms = monotonicMilliseconds() - call_started_at;
    const total_ms = monotonicMilliseconds() - started_at;
    common.log(.DEBUG, "manager transmission passed: event={s} call_ms={d} total_ms={d}", .{ options.event, call_ms, total_ms });
    common.log(.INFO, "lease operation complete: event={s} manager_api=passed call_ms={d} total_ms={d}", .{ options.event, call_ms, total_ms });
}
fn forwardCommittedBatch(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions, started_at: i64) !void {
    const env = init.minimal.environ;
    const config = try loadConfig(init, allocator, options.config_path);
    if (!options.loglevel_set) if (config.loglevel) |level| try common.setLogLevel(level);
    if (config.timeout_seconds <= 0 or config.timeout_seconds > 3600) return error.InvalidTimeout;
    const count_text = envValue(env, "KEA_LEASES4_SIZE", "LEASES4_SIZE") orelse return error.MissingLeaseBatchSize;
    const count = try std.fmt.parseInt(usize, count_text, 10);
    var forwarded: usize = 0;
    for (0..count) |index| {
        const hostname_name = try std.fmt.allocPrint(allocator, "KEA_LEASES4_AT{d}_HOSTNAME", .{index});
        const upstream_hostname_name = try std.fmt.allocPrint(allocator, "LEASES4_AT{d}_HOSTNAME", .{index});
        const hostname = envValue(env, hostname_name, upstream_hostname_name) orelse {
            common.log(.WARN, "leases4_committed entry {d} has no hostname; skipping", .{index});
            continue;
        };
        const ip_name = try std.fmt.allocPrint(allocator, "KEA_LEASES4_AT{d}_ADDRESS", .{index});
        const upstream_ip_name = try std.fmt.allocPrint(allocator, "LEASES4_AT{d}_ADDRESS", .{index});
        const ip = envValue(env, ip_name, upstream_ip_name) orelse {
            common.log(.WARN, "leases4_committed entry {d} has no address; skipping", .{index});
            continue;
        };
        if (!common.validHostLabel(hostname) or !common.validUnboundIpv4(ip)) {
            common.log(.WARN, "leases4_committed entry {d} is not a usable DNS record; skipping", .{index});
            continue;
        }
        const mac_name = try std.fmt.allocPrint(allocator, "KEA_LEASES4_AT{d}_HWADDR", .{index});
        const upstream_mac_name = try std.fmt.allocPrint(allocator, "LEASES4_AT{d}_HWADDR", .{index});
        const lifetime_name = try std.fmt.allocPrint(allocator, "KEA_LEASES4_AT{d}_VALID_LIFETIME", .{index});
        const upstream_lifetime_name = try std.fmt.allocPrint(allocator, "LEASES4_AT{d}_VALID_LIFETIME", .{index});
        try forwardLease(config, allocator, hostname, ip, envValue(env, mac_name, upstream_mac_name) orelse "", envValue(env, lifetime_name, upstream_lifetime_name) orelse "", "lease4_committed");
        forwarded += 1;
    }
    common.log(.INFO, "leases4_committed batch complete: forwarded={d} entries total_ms={d}", .{ forwarded, monotonicMilliseconds() - started_at });
}
fn envValue(env: std.process.Environ, preferred: []const u8, upstream: []const u8) ?[]const u8 {
    return env.getPosix(preferred) orelse env.getPosix(upstream);
}
fn forwardLease(config: HookConfig, allocator: std.mem.Allocator, hostname: []const u8, ip: []const u8, mac: []const u8, lifetime: []const u8, event: []const u8) !void {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"event\":\"");
    try common.jsonEscape(&body.writer, event);
    try body.writer.writeAll("\",\"timestamp\":0,\"lease\":{\"hostname\":\"");
    try common.jsonEscape(&body.writer, hostname);
    try body.writer.writeAll("\",\"ip-address\":\"");
    try common.jsonEscape(&body.writer, ip);
    try body.writer.writeAll("\",\"mac-address\":\"");
    try common.jsonEscape(&body.writer, mac);
    try body.writer.writeAll("\",\"valid-lifetime\":\"");
    try common.jsonEscape(&body.writer, lifetime);
    try body.writer.writeAll("\",\"subnet-id\":\"\",\"query-interface\":\"\"}}");
    try post(config.leaselinkd_address, body.written(), Deadline.init(config.timeout_seconds));
}
fn parseCommand(args: []const []const u8) !?CommandOptions {
    var event: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var loglevel_set = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) return null else if (std.mem.eql(u8, args[i], "--loglevel")) {
            i += 1;
            if (i == args.len) return error.MissingLogLevel;
            try common.setLogLevel(args[i]);
            loglevel_set = true;
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i == args.len) return error.MissingConfigPath;
            config_path = args[i];
        } else if (event == null) event = args[i] else return error.UnexpectedArgument;
    }
    return .{ .event = event orelse return error.MissingEvent, .config_path = config_path, .loglevel_set = loglevel_set };
}
fn printHelp(init: std.process.Init) !void {
    var buffer: [1536]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(
        \\ Usage: kea-leaselink [OPTIONS] EVENT
        \\
        \\ Forward one Kea DHCP lease event to leaselinkd, then exit.
        \\
        \\Arguments:
        \\  EVENT                     Kea event name, for example lease4_committed.
        \\
        \\Options:
        \\  --config <PATH>         Override /etc/leaselinkd/hook.json.
        \\  --loglevel <LEVEL>        Logging level: ERROR, WARN, INFO, or DEBUG. [default: INFO]
        \\  -h, --help                Show this message and exit.
        \\
        \\Lease values are read from KEA_LEASE4_HOSTNAME, KEA_LEASE4_ADDRESS, and
        \\KEA_LEASE4_HWADDR. Transport configuration is read from /etc/leaselinkd/hook.json.
        \\
    );
    try output.interface.flush();
}
fn loadConfig(init: std.process.Init, allocator: std.mem.Allocator, config_path: ?[]const u8) !HookConfig {
    const path = config_path orelse init.minimal.environ.getPosix("KEA_LEASELINK_CONFIG") orelse "/etc/leaselinkd/hook.json";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024));
    return try std.json.parseFromSliceLeaky(HookConfig, allocator, bytes, .{ .ignore_unknown_fields = true });
}
fn post(address: []const u8, body: []const u8, deadline: Deadline) !void {
    if (std.mem.startsWith(u8, address, "unix://")) return postUnix(address[7..], body, deadline);
    if (std.mem.startsWith(u8, address, "tcp://")) return postTcp(address[6..], body, deadline);
    return error.UnsupportedTransport;
}
fn sendEvent(fd: c_int, body: []const u8, deadline: Deadline) !void {
    var request: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&request, "POST /lease_event HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try sendAll(fd, head, deadline);
    try sendAll(fd, body, deadline);
    var response: [64]u8 = undefined;
    try waitFor(fd, c.POLLIN, deadline);
    const n = c.recv(fd, &response, response.len, 0);
    if (n <= 0 or n < 12 or !std.mem.startsWith(u8, response[0..@intCast(n)], "HTTP/1.1 2")) return error.ManagerRejectedEvent;
}
fn postUnix(path: []const u8, body: []const u8, deadline: Deadline) !void {
    if (path.len >= 108) return error.NameTooLong;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    try setNonBlocking(fd);
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    for (path, 0..) |ch, i| addr.sun_path[i] = @intCast(ch);
    const len = @offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1;
    try connectWithDeadline(fd, @ptrCast(&addr), @intCast(len), deadline);
    try sendEvent(fd, body, deadline);
}
fn postTcp(address: []const u8, body: []const u8, deadline: Deadline) !void {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidManagerAddress;
    const host = address[0..colon];
    const port = try std.fmt.parseInt(u16, address[colon + 1 ..], 10);
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    try setNonBlocking(fd);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    const host_z = try std.heap.page_allocator.dupeZ(u8, host);
    if (c.inet_pton(c.AF_INET, host_z.ptr, &addr.sin_addr) != 1) return error.InvalidManagerAddress;
    try connectWithDeadline(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in), deadline);
    try sendEvent(fd, body, deadline);
}
fn monotonicMilliseconds() i64 {
    var value: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &value);
    return @as(i64, @intCast(value.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(value.tv_nsec)), 1_000_000);
}
fn setNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.SocketConfigurationFailed;
}
fn waitFor(fd: c_int, events: c_short, deadline: Deadline) !void {
    var ready = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
    const result = c.poll(&ready, 1, try deadline.remainingMs());
    if (result == 0) return error.ManagerTimeout;
    if (result < 0 or (ready.revents & c.POLLNVAL) != 0 or (ready.revents & events) == 0) return error.SocketFailed;
}
fn connectWithDeadline(fd: c_int, address: *const c.struct_sockaddr, length: c.socklen_t, deadline: Deadline) !void {
    if (c.connect(fd, address, length) == 0) return;
    try waitFor(fd, c.POLLOUT, deadline);
    var socket_error: c_int = 0;
    var socket_error_length: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &socket_error_length) != 0 or socket_error != 0) return error.ConnectFailed;
}
fn sendAll(fd: c_int, bytes: []const u8, deadline: Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFor(fd, c.POLLOUT, deadline);
        const sent = c.send(fd, bytes[offset..].ptr, bytes.len - offset, 0);
        if (sent <= 0) return error.SendFailed;
        offset += @intCast(sent);
    }
}
