const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("sqlite3.h");
});
const Config = struct { opnsense_url: []const u8, loglevel: ?[]const u8 = null, db_path: []const u8 = "/var/lib/leaselinkd/dhcpdb.sqlite", listen_type: []const u8 = "unix", socket_path: []const u8 = "/run/leaselinkd/fifo.pipe", tcp_host: []const u8 = "127.0.0.1", tcp_port: u16 = 9080, domain: []const u8 = "local", managed_description: []const u8 = "Managed by leaselinkd", record_ttl_seconds: i64 = 86400, reconcile_seconds: i64 = 300, queue_max_events: usize = 512, throttle_seconds: i64 = 10, health_check_seconds: i64 = 60, initial_backoff_ms: i64 = 100, max_backoff_ms: i64 = 10000, api_timeout_seconds: i64 = 5, api_test_timeout_seconds: i64 = 60 };
const Secrets = struct { api_key: ?[]const u8 = null, apik_key: ?[]const u8 = null, api_secret: ?[]const u8 = null, apikey_secret: ?[]const u8 = null };
const max_pending_events = 512;
const PendingEvent = struct { body: []u8, hostname: []u8 };
const Runtime = struct { config: Config, key: []const u8, secret: []const u8, db: *c.sqlite3, io: std.Io, started_at: i64, api_worker_fd: c_int = -1, api_worker_pid: c_int = -1, reconfigure_due: ?i64 = null, health_due: i64 = 0, reconcile_due: i64 = 0, health_backoff_ms: i64 = 100, lease_events: u64 = 0, api_calls: u64 = 0, api_get_calls: u64 = 0, api_post_calls: u64 = 0, api_failures: u64 = 0, reconfigures: u64 = 0, health_checks: u64 = 0, health_failures: u64 = 0 };
const Desired = struct { hostname: []const u8, owner_id: []const u8, ip: []const u8, present: bool, expires_at: i64, uuid: ?[]const u8 = null };
var report_requested: std.atomic.Value(u8) = .init(0);
var shutdown_requested: std.atomic.Value(u8) = .init(0);
const Command = enum { run, config_check, api_test };
const CommandOptions = struct { command: Command = .run, config_path: ?[]const u8 = null, secrets_path: ?[]const u8 = null, loglevel_set: bool = false };
const api_worker_error: u64 = std.math.maxInt(u64);
const max_api_frame_bytes = 128 * 1024;
const ApiRequestHeader = extern struct { method: u8, endpoint_len: u32, body_len: u32 };

pub fn main(init: std.process.Init) !void {
    const options = (try parseCommand(init)) orelse {
        try printHelp(init);
        return;
    };
    const allocator = init.arena.allocator();
    switch (options.command) {
        .run => try run(init, allocator, options),
        .config_check => {
            var runtime = try loadRuntime(init, allocator, options);
            defer _ = c.sqlite3_close(runtime.db);
            try validateConfig(&runtime.config);
            common.log(.INFO, "configuration check passed", .{});
            logConfiguration(&runtime, false);
        },
        .api_test => {
            try runApiTest(init, allocator, options);
        },
    }
}
fn runApiTest(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions) !void {
    var runtime = try loadRuntime(init, allocator, options);
    defer _ = c.sqlite3_close(runtime.db);
    defer stopApiWorker(&runtime);
    try validateConfig(&runtime.config);
    _ = c.signal(c.SIGALRM, onApiTestTimeout);
    _ = c.alarm(@intCast(runtime.config.api_test_timeout_seconds));
    defer {
        _ = c.alarm(0);
        _ = c.signal(c.SIGALRM, c.SIG_DFL);
    }
    common.log(.INFO, "testing OPNsense API status ({d} second deadline)", .{runtime.config.api_test_timeout_seconds});
    _ = try apiGet(&runtime, allocator, "/service/status");
    common.log(.INFO, "testing OPNsense Unbound reconfigure", .{});
    _ = try apiPost(&runtime, allocator, "/service/reconfigure", "{}");
    common.log(.INFO, "API test passed", .{});
}
fn onApiTestTimeout(_: c_int) callconv(.c) void {
    const message = "[ERROR] --api-test timed out after 60 seconds\n";
    _ = c.write(2, message.ptr, message.len);
    c._exit(124);
}
fn run(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions) !void {
    var runtime = try loadRuntime(init, allocator, options);
    defer _ = c.sqlite3_close(runtime.db);
    defer stopApiWorker(&runtime);
    try validateConfig(&runtime.config);
    const unix_mode = std.mem.eql(u8, runtime.config.listen_type, "unix");
    const fd = if (unix_mode) try listenUnix(runtime.config.socket_path) else if (std.mem.eql(u8, runtime.config.listen_type, "tcp")) try listenTcp(runtime.config.tcp_host, runtime.config.tcp_port) else return error.InvalidListenType;
    defer _ = c.close(fd);
    defer if (unix_mode) std.Io.Dir.cwd().deleteFile(init.io, runtime.config.socket_path) catch {};
    _ = c.signal(c.SIGUSR1, onSigusr1);
    _ = c.signal(c.SIGTERM, onShutdown);
    _ = c.signal(c.SIGINT, onShutdown);
    common.log(.INFO, "leaselinkd v{s} starting; architecture={s}; loglevel={s}", .{ common.version, @tagName(builtin.cpu.arch), @tagName(common.logLevel()) });
    common.log(.INFO, "listening via {s}", .{runtime.config.listen_type});
    logConfiguration(&runtime, false);
    healthCheck(&runtime, allocator, true);
    while (true) {
        if (shutdown_requested.load(.acquire) != 0) {
            common.log(.INFO, "shutdown requested; durable work remains in SQLite for the next start", .{});
            return;
        }
        var ready = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const result = c.poll(&ready, 1, 250);
        if (result > 0 and (ready.revents & c.POLLIN) != 0) while (true) {
            const client = c.accept(fd, null, null);
            if (client >= 0) {
                processConnection(client, allocator, &runtime) catch |err| common.log(.ERROR, "lease event failed: {t}", .{err});
                _ = c.close(client);
            } else break;
        };
        if (report_requested.swap(0, .acq_rel) != 0) {
            logConfiguration(&runtime, false);
            logMetrics(&runtime);
        }
        serviceTimers(&runtime, allocator);
    }
}
fn parseCommand(init: std.process.Init) !?CommandOptions {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = CommandOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) return null else if (std.mem.eql(u8, args[i], "--loglevel")) {
            i += 1;
            if (i == args.len) return error.MissingLogLevel;
            try common.setLogLevel(args[i]);
            options.loglevel_set = true;
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i == args.len) return error.MissingConfigPath;
            options.config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--secret")) {
            i += 1;
            if (i == args.len) return error.MissingSecretPath;
            options.secrets_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--config-check")) {
            if (options.command != .run) return error.ConflictingCommand;
            options.command = .config_check;
        } else if (std.mem.eql(u8, args[i], "--api-test")) {
            if (options.command != .run) return error.ConflictingCommand;
            options.command = .api_test;
        } else return error.UnexpectedArgument;
    }
    return options;
}
fn printHelp(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(
        \\ Usage: leaselinkd [OPTIONS]
        \\
        \\ Persistent Kea lease-event manager for OPNsense Unbound.
        \\
        \\Options:
        \\  --config <PATH>         Override /etc/leaselinkd/config.json.
        \\  --secret <PATH>         Override /etc/leaselinkd/secrets.json.
        \\  --config-check           Validate configuration, credentials, and SQLite access, then exit.
        \\  --api-test               Check the OPNsense API and request an Unbound reconfigure, then exit.
        \\  --loglevel <LEVEL>       Logging level: ERROR, WARN, INFO, or DEBUG. [default: INFO]
        \\  -h, --help               Show this message and exit.
        \\
        \\The manager listens using /etc/leaselinkd/config.json. --api-test has a 60-second
        \\overall deadline; every OPNsense API request has a five-second deadline.
        \\
    );
    try output.interface.flush();
}
fn validateConfig(config: *const Config) !void {
    if (!std.mem.startsWith(u8, config.opnsense_url, "https://") and !std.mem.startsWith(u8, config.opnsense_url, "http://")) return error.InvalidOpnsenseUrl;
    if (config.record_ttl_seconds <= 0 or config.reconcile_seconds <= 0 or config.queue_max_events == 0 or config.queue_max_events > max_pending_events or config.throttle_seconds < 0 or config.health_check_seconds <= 0 or config.initial_backoff_ms <= 0 or config.max_backoff_ms < config.initial_backoff_ms or config.api_timeout_seconds <= 0 or config.api_timeout_seconds > 3600 or config.api_test_timeout_seconds <= 0 or config.api_test_timeout_seconds > 3600) return error.InvalidTimerConfiguration;
    if (std.mem.eql(u8, config.listen_type, "unix")) {
        if (config.socket_path.len == 0 or config.socket_path.len >= 108) return error.InvalidSocketPath;
    } else if (std.mem.eql(u8, config.listen_type, "tcp")) {
        if (config.tcp_host.len == 0 or config.tcp_port == 0) return error.InvalidTcpConfiguration;
    } else return error.InvalidListenType;
}
fn onSigusr1(_: c_int) callconv(.c) void {
    report_requested.store(1, .release);
}
fn onShutdown(_: c_int) callconv(.c) void {
    shutdown_requested.store(1, .release);
}
fn logConfiguration(r: *const Runtime, debug: bool) void {
    if (debug) common.log(.DEBUG, "config: api={s}, listener={s}, socket={s}, tcp={s}:{d}, domain={s}, throttle={d}s, health={d}s, api_timeout={d}s, api_test_timeout={d}s", .{ r.config.opnsense_url, r.config.listen_type, r.config.socket_path, r.config.tcp_host, r.config.tcp_port, r.config.domain, r.config.throttle_seconds, r.config.health_check_seconds, r.config.api_timeout_seconds, r.config.api_test_timeout_seconds }) else common.log(.INFO, "config: api={s}, listener={s}, socket={s}, tcp={s}:{d}, domain={s}, throttle={d}s, health={d}s, api_timeout={d}s, api_test_timeout={d}s", .{ r.config.opnsense_url, r.config.listen_type, r.config.socket_path, r.config.tcp_host, r.config.tcp_port, r.config.domain, r.config.throttle_seconds, r.config.health_check_seconds, r.config.api_timeout_seconds, r.config.api_test_timeout_seconds });
}
fn logMetrics(r: *const Runtime) void {
    common.log(.INFO, "metrics: runtime={d}s lease_events={d} api_calls={d} get={d} post={d} api_failures={d} health_checks={d} health_failures={d} reconfigures={d}", .{ nowSeconds() - r.started_at, r.lease_events, r.api_calls, r.api_get_calls, r.api_post_calls, r.api_failures, r.health_checks, r.health_failures, r.reconfigures });
}
fn loadRuntime(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions) !Runtime {
    const config_path = options.config_path orelse init.minimal.environ.getPosix("LEASELINKD_CONFIG") orelse "/etc/leaselinkd/config.json";
    const secrets_path = options.secrets_path orelse init.minimal.environ.getPosix("LEASELINKD_SECRETS") orelse "/etc/leaselinkd/secrets.json";
    const cb = try std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .limited(128 * 1024));
    const sb = try std.Io.Dir.cwd().readFileAlloc(init.io, secrets_path, allocator, .limited(128 * 1024));
    const config = try std.json.parseFromSliceLeaky(Config, allocator, cb, .{ .ignore_unknown_fields = true });
    if (!options.loglevel_set) if (config.loglevel) |level| try common.setLogLevel(level);
    const secrets = try std.json.parseFromSliceLeaky(Secrets, allocator, sb, .{ .ignore_unknown_fields = true });
    const key = secrets.api_key orelse secrets.apik_key orelse return error.MissingApiKey;
    const secret = secrets.api_secret orelse secrets.apikey_secret orelse return error.MissingApiSecret;
    const db_path = try allocator.dupeZ(u8, config.db_path);
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path.ptr, &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    errdefer _ = c.sqlite3_close(db);
    try sql(db.?, "PRAGMA journal_mode=WAL;");
    try sql(db.?, "CREATE TABLE IF NOT EXISTS overrides (hostname TEXT PRIMARY KEY, uuid TEXT NOT NULL, ip_address TEXT NOT NULL);");
    try sql(db.?, "CREATE TABLE IF NOT EXISTS desired_overrides (hostname TEXT PRIMARY KEY, owner_id TEXT NOT NULL, ip_address TEXT NOT NULL, present INTEGER NOT NULL, expires_at INTEGER NOT NULL, uuid TEXT, dirty INTEGER NOT NULL DEFAULT 1, next_attempt INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0);");
    return .{ .config = config, .key = key, .secret = secret, .db = db.?, .io = init.io, .started_at = nowSeconds(), .health_backoff_ms = config.initial_backoff_ms, .reconcile_due = nowSeconds() };
}
fn listenUnix(path: []const u8) !c_int {
    if (path.len >= 108) return error.NameTooLong;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var path_z: [108:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = c.unlink(&path_z);
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    for (path, 0..) |ch, i| addr.sun_path[i] = @intCast(ch);
    const len = @offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1;
    if (c.bind(fd, @ptrCast(&addr), @intCast(len)) != 0 or c.chmod(&path_z, 0o660) != 0 or c.listen(fd, max_pending_events) != 0 or c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK) < 0) return error.BindFailed;
    return fd;
}
fn listenTcp(host: []const u8, port: u16) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var reuse: c_int = 1;
    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &reuse, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    const host_z = try std.heap.page_allocator.dupeZ(u8, host);
    if (c.inet_pton(c.AF_INET, host_z.ptr, &addr.sin_addr) != 1) return error.InvalidTcpHost;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(fd, max_pending_events) != 0 or c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK) < 0) return error.BindFailed;
    return fd;
}
fn nowSeconds() i64 {
    return @intCast(c.time(null));
}
fn serviceTimers(r: *Runtime, allocator: std.mem.Allocator) void {
    expireDesired(r) catch |err| common.log(.ERROR, "TTL cleanup failed: {t}", .{err});
    const due_work = nextDesired(r.db, allocator, nowSeconds()) catch |err| {
        common.log(.ERROR, "durable work lookup failed: {t}", .{err});
        return;
    };
    if (due_work) |desired| {
        processDesired(r, allocator, desired) catch |err| {
            scheduleRetry(r.db, desired.hostname) catch |db_err| common.log(.ERROR, "durable retry scheduling failed: {t}", .{db_err});
            common.log(.WARN, "durable lease work failed: {t}", .{err});
        };
        return;
    }
    const now = nowSeconds();
    if (now >= r.reconcile_due) {
        reconcile(r, allocator) catch |err| common.log(.WARN, "OPNsense reconciliation failed: {t}", .{err});
        r.reconcile_due = now + r.config.reconcile_seconds;
        return;
    }
    if (r.reconfigure_due) |due| if (now >= due) {
        common.log(.INFO, "calling Unbound reconfigure", .{});
        _ = apiPost(r, allocator, "/service/reconfigure", "{}") catch |err| {
            common.log(.ERROR, "Unbound reconfigure failed: {t}", .{err});
            r.reconfigure_due = now + 1;
            return;
        };
        r.reconfigures += 1;
        r.reconfigure_due = null;
    };
    if (now >= r.health_due) healthCheck(r, allocator, false);
}
fn requestReconfigure(r: *Runtime) void {
    const due = nowSeconds() + @max(@as(i64, 0), r.config.throttle_seconds);
    r.reconfigure_due = if (r.reconfigure_due) |existing| @min(existing, due) else due;
    common.log(.DEBUG, "reconfigure scheduled for {d}", .{r.reconfigure_due.?});
}
fn healthCheck(r: *Runtime, allocator: std.mem.Allocator, startup: bool) void {
    r.health_checks += 1;
    common.log(.DEBUG, "checking OPNsense health", .{});
    if (apiGet(r, allocator, "/service/status")) |response| {
        r.health_backoff_ms = r.config.initial_backoff_ms;
        r.health_due = nowSeconds() + @max(@as(i64, 1), r.config.health_check_seconds);
        if (startup) {
            const Status = struct { status: ?[]const u8 = null };
            const status = std.json.parseFromSlice(Status, allocator, response, .{ .ignore_unknown_fields = true }) catch null;
            if (status) |parsed| {
                defer parsed.deinit();
                common.log(.INFO, "OPNsense startup health check passed: api={s}; transport={s}; service_status={s}; next_check={d}s", .{ r.config.opnsense_url, if (std.mem.startsWith(u8, r.config.opnsense_url, "https://")) "HTTPS (system trust verified)" else "HTTP", parsed.value.status orelse "unknown", @max(@as(i64, 1), r.config.health_check_seconds) });
            } else {
                common.log(.INFO, "OPNsense startup health check passed: api={s}; transport={s}; service_status=unparseable; next_check={d}s", .{ r.config.opnsense_url, if (std.mem.startsWith(u8, r.config.opnsense_url, "https://")) "HTTPS (system trust verified)" else "HTTP", @max(@as(i64, 1), r.config.health_check_seconds) });
            }
        } else common.log(.DEBUG, "OPNsense health check succeeded", .{});
    } else |err| {
        r.health_failures += 1;
        const delay = @max(@as(i64, 1), @divTrunc(r.health_backoff_ms + 999, 1000));
        common.log(.WARN, "OPNsense health check failed: {t}; retrying in {d}s", .{ err, delay });
        r.health_due = nowSeconds() + delay;
        r.health_backoff_ms = @min(r.health_backoff_ms * 2, r.config.max_backoff_ms);
    }
}
fn processConnection(fd: c_int, allocator: std.mem.Allocator, r: *Runtime) !void {
    var buffer: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        const raw = c.recv(fd, buffer[total..].ptr, buffer.len - total, 0);
        if (raw <= 0) return;
        total += @intCast(raw);
        const request = buffer[0..total];
        const at = std.mem.indexOf(u8, request, "\r\n\r\n") orelse continue;
        const content_length = headerContentLength(request[0..at]) orelse {
            common.log(.WARN, "invalid HTTP headers", .{});
            return respond(fd, 400);
        };
        if (total < at + 4 + content_length) continue;
        if (!std.mem.startsWith(u8, request, "POST /lease_event ")) return respond(fd, 404);
        const event = std.json.parseFromSliceLeaky(common.Event, allocator, request[at + 4 .. at + 4 + content_length], .{ .ignore_unknown_fields = true }) catch |err| {
            common.log(.WARN, "invalid lease-event JSON: {t}", .{err});
            return respond(fd, 400);
        };
        if (common.leaseOperation(event.event) == null) {
            common.log(.WARN, "rejecting unsupported Kea hook point: {s}", .{event.event});
            return respond(fd, 422);
        }
        if (!common.validHostLabel(event.lease.hostname)) {
            common.log(.WARN, "ignoring invalid hostname in {s}", .{event.event});
            return respond(fd, 422);
        }
        if (!common.isRemovalEvent(event.event) and !common.validUnboundIpv4(event.lease.@"ip-address")) {
            common.log(.WARN, "ignoring invalid or loopback IPv4 lease address in {s}", .{event.event});
            return respond(fd, 422);
        }
        persistDesired(r, allocator, event) catch |err| {
            common.log(.ERROR, "persisting lease intent failed: {t}", .{err});
            return respond(fd, 503);
        };
        r.lease_events += 1;
        common.log(.INFO, "persisted lease event={s} host={s} ip={s}", .{ event.event, event.lease.hostname, event.lease.@"ip-address" });
        return respond(fd, 202);
    }
    return respond(fd, 400);
}
fn headerContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Content-Length:")) return std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10) catch null;
    }
    return null;
}
fn respond(fd: c_int, code: u16) !void {
    const text = if (code == 202) "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n" else if (code == 404) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" else if (code == 422) "HTTP/1.1 422 Unprocessable Content\r\nContent-Length: 0\r\n\r\n" else if (code == 503) "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" else "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    if (c.send(fd, text.ptr, text.len, 0) < 0) return error.SendFailed;
}
fn persistDesired(r: *Runtime, allocator: std.mem.Allocator, event: common.Event) !void {
    const owner = (try ownerFor(r.db, allocator, event.lease.hostname)) orelse try newOwnerId(r.io, allocator);
    const present = !common.isRemovalEvent(event.event);
    const lease_ttl = std.fmt.parseInt(i64, event.lease.@"valid-lifetime", 10) catch r.config.record_ttl_seconds;
    const expires = nowSeconds() + @max(@as(i64, 1), if (present) lease_ttl else r.config.record_ttl_seconds);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(r.db, "INSERT INTO desired_overrides(hostname,owner_id,ip_address,present,expires_at,dirty,next_attempt,failures) VALUES(?,?,?,?,?,1,0,0) ON CONFLICT(hostname) DO UPDATE SET ip_address=excluded.ip_address,present=excluded.present,expires_at=excluded.expires_at,dirty=1,next_attempt=0,failures=0", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, event.lease.hostname.ptr, @intCast(event.lease.hostname.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 2, owner.ptr, @intCast(owner.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 3, event.lease.@"ip-address".ptr, @intCast(event.lease.@"ip-address".len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_int(stmt, 4, if (present) 1 else 0);
    _ = c.sqlite3_bind_int64(stmt, 5, expires);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn newOwnerId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    var text: [32]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        text[i * 2] = alphabet[byte >> 4];
        text[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return allocator.dupe(u8, &text);
}
fn ownerFor(db: *c.sqlite3, allocator: std.mem.Allocator, hostname: []const u8) !?[]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT owner_id FROM desired_overrides WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
}
fn expireDesired(r: *Runtime) !void {
    try sql(r.db, "UPDATE desired_overrides SET present=0,dirty=1,next_attempt=0 WHERE present=1 AND expires_at <= strftime('%s','now')");
}
fn nextDesired(db: *c.sqlite3, allocator: std.mem.Allocator, now: i64) !?Desired {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT hostname,owner_id,ip_address,present,expires_at,uuid FROM desired_overrides WHERE dirty=1 AND next_attempt<=? ORDER BY next_attempt,hostname LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, now);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .hostname = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))), .owner_id = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))), .ip = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))), .present = c.sqlite3_column_int(stmt, 3) != 0, .expires_at = c.sqlite3_column_int64(stmt, 4), .uuid = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) null else try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))) };
}
fn processDesired(r: *Runtime, allocator: std.mem.Allocator, desired: Desired) !void {
    if (desired.present) try applyDesired(r, allocator, desired) else try removeDesired(r, allocator, desired);
}
fn applyDesired(r: *Runtime, allocator: std.mem.Allocator, desired: Desired) !void {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"host\":{\"enabled\":\"1\",\"hostname\":\"");
    try common.jsonEscape(&body.writer, desired.hostname);
    try body.writer.writeAll("\",\"domain\":\"");
    try common.jsonEscape(&body.writer, r.config.domain);
    try body.writer.writeAll("\",\"rr\":\"A\",\"server\":\"");
    try common.jsonEscape(&body.writer, desired.ip);
    try body.writer.writeAll("\",\"description\":\"");
    try common.jsonEscape(&body.writer, r.config.managed_description);
    try body.writer.writeAll("; leaselinkd:");
    try common.jsonEscape(&body.writer, desired.hostname);
    try body.writer.writeByte(':');
    try common.jsonEscape(&body.writer, desired.owner_id);
    try body.writer.writeAll("\"}}");
    const endpoint = if (desired.uuid) |uuid| try std.fmt.allocPrint(allocator, "/settings/set_host_override/{s}", .{uuid}) else "/settings/add_host_override";
    const response = try apiPost(r, allocator, endpoint, body.written());
    const uuid = desired.uuid orelse try responseUuid(allocator, response);
    try markApplied(r.db, desired.hostname, uuid);
    try store(r.db, desired.hostname, uuid, desired.ip);
    requestReconfigure(r);
}
fn removeDesired(r: *Runtime, allocator: std.mem.Allocator, desired: Desired) !void {
    if (desired.uuid) |uuid| {
        const endpoint = try std.fmt.allocPrint(allocator, "/settings/del_host_override/{s}", .{uuid});
        _ = try apiPost(r, allocator, endpoint, "{}");
        requestReconfigure(r);
    }
    try sqlDeleteDesired(r.db, desired.hostname);
    try delete(r.db, desired.hostname);
}
fn markApplied(db: *c.sqlite3, hostname: []const u8, uuid: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "UPDATE desired_overrides SET uuid=?,dirty=0,failures=0 WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, uuid.ptr, @intCast(uuid.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 2, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn scheduleRetry(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "UPDATE desired_overrides SET failures=failures+1,next_attempt=strftime('%s','now') + MIN(300, 1 << MIN(8,failures)) WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn sqlDeleteDesired(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "DELETE FROM desired_overrides WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn reconcile(r: *Runtime, allocator: std.mem.Allocator) !void {
    const Remote = struct { uuid: ?[]const u8 = null, description: ?[]const u8 = null };
    const Reply = struct { rows: ?[]Remote = null };
    const response = try apiGet(r, allocator, "/settings/search_host_override");
    const reply = try std.json.parseFromSliceLeaky(Reply, allocator, response, .{ .ignore_unknown_fields = true });
    for (reply.rows orelse &.{}) |remote| {
        const uuid = remote.uuid orelse continue;
        const description = remote.description orelse continue;
        const marker = std.mem.lastIndexOf(u8, description, "; leaselinkd:") orelse continue;
        const suffix = description[marker + "; leaselinkd:".len ..];
        const colon = std.mem.lastIndexOfScalar(u8, suffix, ':') orelse continue;
        const owner = suffix[colon + 1 ..];
        if (!(try reconcileOwner(r.db, owner, uuid))) {
            const endpoint = try std.fmt.allocPrint(allocator, "/settings/del_host_override/{s}", .{uuid});
            _ = try apiPost(r, allocator, endpoint, "{}");
            requestReconfigure(r);
            common.log(.INFO, "reconciliation removed stale managed override uuid={s}", .{uuid});
        }
    }
    // Reassert desired state after pruning. This repairs manually deleted remote
    // entries and any uncertain timeout without trusting an incomplete search row.
    try sql(r.db, "UPDATE desired_overrides SET dirty=1,next_attempt=0 WHERE present=1");
}
fn reconcileOwner(db: *c.sqlite3, owner: []const u8, remote_uuid: []const u8) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT hostname,uuid FROM desired_overrides WHERE owner_id=? AND present=1", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, owner.ptr, @intCast(owner.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return false;
    const hostname = std.mem.span(c.sqlite3_column_text(stmt, 0));
    if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) {
        try markApplied(db, hostname, remote_uuid);
        return true;
    }
    return std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), remote_uuid);
}
fn upsert(r: *Runtime, allocator: std.mem.Allocator, lease: common.Lease) !void {
    const old = try lookup(r.db, allocator, lease.hostname);
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"host\":{\"enabled\":\"1\",\"hostname\":\"");
    try common.jsonEscape(&body.writer, lease.hostname);
    try body.writer.writeAll("\",\"domain\":\"");
    try common.jsonEscape(&body.writer, r.config.domain);
    try body.writer.writeAll("\",\"rr\":\"A\",\"server\":\"");
    try common.jsonEscape(&body.writer, lease.@"ip-address");
    try body.writer.writeAll("\",\"description\":\"");
    try common.jsonEscape(&body.writer, r.config.managed_description);
    try body.writer.writeAll("\"}}");
    const endpoint = if (old) |uuid| try std.fmt.allocPrint(allocator, "/settings/set_host_override/{s}", .{uuid}) else "/settings/add_host_override";
    const response = try apiPost(r, allocator, endpoint, body.written());
    const uuid = if (old) |value| value else try responseUuid(allocator, response);
    try store(r.db, lease.hostname, uuid, lease.@"ip-address");
    requestReconfigure(r);
}
fn remove(r: *Runtime, allocator: std.mem.Allocator, hostname: []const u8) !void {
    const uuid = (try lookup(r.db, allocator, hostname)) orelse return;
    const endpoint = try std.fmt.allocPrint(allocator, "/settings/del_host_override/{s}", .{uuid});
    _ = try apiPost(r, allocator, endpoint, "{}");
    try delete(r.db, hostname);
    requestReconfigure(r);
}
fn apiPost(r: *Runtime, allocator: std.mem.Allocator, endpoint: []const u8, body: []const u8) ![]u8 {
    r.api_calls += 1;
    r.api_post_calls += 1;
    common.log(.INFO, "OPNsense POST {s}", .{endpoint});
    return api(r, allocator, .POST, endpoint, body);
}
fn apiGet(r: *Runtime, allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    r.api_calls += 1;
    r.api_get_calls += 1;
    common.log(.DEBUG, "OPNsense GET {s}", .{endpoint});
    return api(r, allocator, .GET, endpoint, null);
}
fn api(r: *Runtime, allocator: std.mem.Allocator, method: std.http.Method, endpoint: []const u8, body: ?[]const u8) ![]u8 {
    return apiWithTimeout(r, allocator, method, endpoint, body) catch |err| {
        r.api_failures += 1;
        return err;
    };
}
fn apiWithTimeout(r: *const Runtime, allocator: std.mem.Allocator, method: std.http.Method, endpoint: []const u8, body: ?[]const u8) ![]u8 {
    const runtime: *Runtime = @constCast(r);
    try startApiWorker(runtime);
    const deadline = monotonicMilliseconds() + r.config.api_timeout_seconds * 1000;
    const payload = body orelse "";
    if (endpoint.len > max_api_frame_bytes or payload.len > max_api_frame_bytes) return error.ApiFrameTooLarge;
    const header = ApiRequestHeader{ .method = if (method == .GET) 0 else 1, .endpoint_len = @intCast(endpoint.len), .body_len = @intCast(payload.len) };
    writeFdUntil(runtime.api_worker_fd, std.mem.asBytes(&header), deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    writeFdUntil(runtime.api_worker_fd, endpoint, deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    writeFdUntil(runtime.api_worker_fd, payload, deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    var encoded_length: u64 = undefined;
    readFdUntil(runtime.api_worker_fd, std.mem.asBytes(&encoded_length), deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    if (encoded_length == api_worker_error or encoded_length > max_api_frame_bytes) {
        stopApiWorker(runtime);
        common.log(.WARN, "OPNsense request failed; for HTTPS certificate diagnostics, run /usr/share/leaselinkd/check-firewall-certificate.sh --host <firewall-host> --port <https-port>", .{});
        return error.OpnsenseRequestFailed;
    }
    const response = try allocator.alloc(u8, @intCast(encoded_length));
    readFdUntil(runtime.api_worker_fd, response, deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    return response;
}
fn startApiWorker(r: *Runtime) !void {
    if (r.api_worker_fd >= 0) return;
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets) != 0) return error.ApiWorkerSocketFailed;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
        return error.ApiForkFailed;
    }
    if (pid == 0) {
        _ = c.close(sockets[0]);
        apiWorkerLoop(r, sockets[1]);
        _ = c.close(sockets[1]);
        c._exit(0);
    }
    _ = c.close(sockets[1]);
    r.api_worker_fd = sockets[0];
    r.api_worker_pid = pid;
    common.log(.DEBUG, "started persistent OPNsense API worker pid={d}", .{pid});
}
fn stopApiWorker(r: *Runtime) void {
    if (r.api_worker_fd >= 0) _ = c.close(r.api_worker_fd);
    if (r.api_worker_pid > 0) {
        _ = c.kill(r.api_worker_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(r.api_worker_pid, &status, 0);
    }
    r.api_worker_fd = -1;
    r.api_worker_pid = -1;
}
fn apiWorkerLoop(r: *const Runtime, fd: c_int) void {
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = r.io };
    defer client.deinit();
    while (true) {
        var header: ApiRequestHeader = undefined;
        readFdExact(fd, std.mem.asBytes(&header)) catch return;
        if (header.method > 1 or header.endpoint_len > max_api_frame_bytes or header.body_len > max_api_frame_bytes) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const endpoint = allocator.alloc(u8, header.endpoint_len) catch return;
        const body = allocator.alloc(u8, header.body_len) catch return;
        readFdExact(fd, endpoint) catch return;
        readFdExact(fd, body) catch return;
        const response = apiRequestWithClient(r, allocator, &client, if (header.method == 0) .GET else .POST, endpoint, if (header.body_len == 0) null else body) catch |err| {
            common.log(.DEBUG, "persistent OPNsense worker request failed: {t}", .{err});
            writeWorkerResponse(fd, null) catch return;
            continue;
        };
        writeWorkerResponse(fd, response) catch return;
    }
}
fn writeWorkerResponse(fd: c_int, response: ?[]const u8) !void {
    var length: u64 = if (response) |value| @intCast(value.len) else api_worker_error;
    try writeFdAll(fd, std.mem.asBytes(&length));
    if (response) |value| try writeFdAll(fd, value);
}
fn monotonicMilliseconds() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}
fn waitFd(fd: c_int, events: c_short, deadline: i64) !void {
    const remaining = deadline - monotonicMilliseconds();
    if (remaining <= 0) return error.ApiTimeout;
    var ready = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
    const result = c.poll(&ready, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
    if (result == 0) return error.ApiTimeout;
    if (result < 0 or (ready.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) return error.ApiWorkerFailed;
}
fn writeFdUntil(fd: c_int, bytes: []const u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFd(fd, c.POLLOUT, deadline);
        const written = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0) return error.ApiWorkerFailed;
        offset += @intCast(written);
    }
}
fn readFdUntil(fd: c_int, bytes: []u8, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFd(fd, c.POLLIN, deadline);
        const received = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (received <= 0) return error.ApiWorkerFailed;
        offset += @intCast(received);
    }
}
fn apiRequestWithClient(r: *const Runtime, allocator: std.mem.Allocator, client: *std.http.Client, method: std.http.Method, endpoint: []const u8, body: ?[]const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ r.config.opnsense_url, endpoint });
    const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ r.key, r.secret });
    const encoded_len = std.base64.standard.Encoder.calcSize(credentials.len);
    const authorization = try allocator.alloc(u8, "Basic ".len + encoded_len);
    @memcpy(authorization[0..6], "Basic ");
    _ = std.base64.standard.Encoder.encode(authorization[6..], credentials);
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();
    const result = try client.fetch(.{ .location = .{ .url = url }, .method = method, .payload = body, .headers = .{ .authorization = .{ .override = authorization } }, .extra_headers = if (body != null) &.{.{ .name = "content-type", .value = "application/json" }} else &.{}, .response_writer = &response.writer });
    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) {
        common.log(.DEBUG, "OPNsense {s} {s} returned HTTP {d}", .{ @tagName(method), endpoint, code });
        return error.OpnsenseRequestFailed;
    }
    return try allocator.dupe(u8, response.written());
}
fn writeFdAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0) return error.ApiPipeWriteFailed;
        offset += @intCast(written);
    }
}
fn readFdExact(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const received = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (received <= 0) return error.ApiChildFailed;
        offset += @intCast(received);
    }
}
fn responseUuid(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const Reply = struct { uuid: ?[]const u8 = null };
    const reply = try std.json.parseFromSliceLeaky(Reply, allocator, response, .{ .ignore_unknown_fields = true });
    return reply.uuid orelse error.OpnsenseDidNotReturnUuid;
}
fn sql(db: *c.sqlite3, statement: [:0]const u8) !void {
    if (c.sqlite3_exec(db, statement, null, null, null) != c.SQLITE_OK) return error.SqliteFailed;
}
fn lookup(db: *c.sqlite3, allocator: std.mem.Allocator, hostname: []const u8) !?[]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT uuid FROM overrides WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
}
fn store(db: *c.sqlite3, hostname: []const u8, uuid: []const u8, ip: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "INSERT INTO overrides(hostname,uuid,ip_address) VALUES(?,?,?) ON CONFLICT(hostname) DO UPDATE SET uuid=excluded.uuid,ip_address=excluded.ip_address", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 2, uuid.ptr, @intCast(uuid.len), c.SQLITE_TRANSIENT);
    _ = c.sqlite3_bind_text(stmt, 3, ip.ptr, @intCast(ip.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn delete(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "DELETE FROM overrides WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
