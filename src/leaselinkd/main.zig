const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const prometheus = @import("prometheus.zig");
const httpz = @import("httpz");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
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
    @cInclude("spawn.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("sqlite3.h");
});
const Config = struct { opnsense_url: []const u8, allow_insecure_http: bool = false, loglevel: ?[]const u8 = null, db_path: []const u8 = "/var/lib/leaselinkd/dhcpdb.sqlite", listen_type: []const u8 = "unix", socket_path: []const u8 = "/run/leaselinkd/fifo.pipe", tcp_host: []const u8 = "127.0.0.1", tcp_port: u16 = 9080, metrics_enabled: bool = true, metrics_host: []const u8 = "127.0.0.1", metrics_port: u16 = 9108, dns_servers: []const []const u8 = &.{}, domain: []const u8 = "local", managed_description: []const u8 = "Managed by leaselinkd", record_ttl_seconds: i64 = 86400, reconcile_seconds: i64 = 300, queue_max_events: usize = 512, throttle_seconds: i64 = 10, health_check_seconds: i64 = 60, initial_backoff_ms: i64 = 100, max_backoff_ms: i64 = 10000, api_timeout_seconds: i64 = 5, api_test_timeout_seconds: i64 = 60 };
const Secrets = struct { api_key: ?[]const u8 = null, apik_key: ?[]const u8 = null, api_secret: ?[]const u8 = null, apikey_secret: ?[]const u8 = null };
const max_pending_events = 512;
const max_accepts_per_iteration = 8;
const lease_request_timeout_ms = 1000;
const PendingEvent = struct { body: []u8, hostname: []u8 };
const LoadedConfiguration = struct { config: Config, key: []const u8, secret: []const u8 };
const Runtime = struct { config: Config, key: []const u8, secret: []const u8, db: *c.sqlite3, io: std.Io, started_at: i64, api_worker_fd: c_int = -1, api_worker_pid: c_int = -1, reconfigure_due: ?i64 = null, health_due: i64 = 0, reconcile_due: i64 = 0, health_backoff_ms: i64 = 100, lease_events: u64 = 0, api_calls: u64 = 0, api_get_calls: u64 = 0, api_post_calls: u64 = 0, api_failures: u64 = 0, reconfigures: u64 = 0, health_checks: u64 = 0, health_failures: u64 = 0 };
const Desired = struct { hostname: []const u8, owner_id: []const u8, ip: []const u8, present: bool, expires_at: i64, uuid: ?[]const u8 = null };
var report_requested: std.atomic.Value(u8) = .init(0);
var resync_requested: std.atomic.Value(u8) = .init(0);
var shutdown_requested: std.atomic.Value(u8) = .init(0);
const Command = enum { run, config_check, api_test, api_worker };
const CommandOptions = struct { command: Command = .run, config_path: ?[]const u8 = null, secrets_path: ?[]const u8 = null, worker_fd: ?c_int = null, loglevel_set: bool = false };
const api_worker_error: u64 = std.math.maxInt(u64);
const max_api_frame_bytes = 128 * 1024;
const ApiRequestHeader = extern struct { method: u8, endpoint_len: u32, body_len: u32 };
const ApiWorkerResponse = extern struct { response_len: u64, elapsed_ms: u64 };
const ApiWorkerBootstrap = extern struct { magic: u32 = 0x4c4c4150, version: u32 = 1, url_len: u32, key_len: u32, secret_len: u32 };
const api_worker_ready: u8 = 1;
const WorkerConfiguration = struct { opnsense_url: []u8, key: []u8, secret: []u8 };
const PrometheusServer = struct {
    server: httpz.Server(MetricsHandler),
    thread: std.Thread,

    fn init(init_: std.process.Init, allocator: std.mem.Allocator, config: *const Config) !PrometheusServer {
        const address: httpz.Config.Address = if (std.mem.eql(u8, config.metrics_host, "127.0.0.1")) .localhost(config.metrics_port) else if (std.mem.eql(u8, config.metrics_host, "0.0.0.0")) .all(config.metrics_port) else return error.InvalidMetricsHost;
        var server = try httpz.Server(MetricsHandler).init(init_.io, allocator, .{
            .address = address,
            .thread_pool = .{ .count = 1, .backlog = 16, .buffer_size = 4096 },
            .request = .{ .max_body_size = 1024, .buffer_size = 4096 },
            .timeout = .{ .request = 5, .keepalive = 5, .request_count = 16 },
        }, .{});
        errdefer server.deinit();
        return .{ .thread = try server.listenInNewThread(), .server = server };
    }

    fn deinit(self: *PrometheusServer) void {
        self.server.stop();
        self.thread.join();
        self.server.deinit();
    }
};

const MetricsHandler = struct {
    pub fn handle(_: MetricsHandler, req: *httpz.Request, res: *httpz.Response) void {
        if (!std.mem.eql(u8, req.url.path, "/metrics")) {
            res.status = 404;
            res.body = "Not found\n";
            return;
        }
        res.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
        const writer = res.writer();
        prometheus.write(writer) catch {
            res.status = 500;
            res.clearWriter();
            res.body = "Unable to render metrics\n";
            return;
        };
        httpz.writeMetrics(writer) catch {
            res.status = 500;
            res.clearWriter();
            res.body = "Unable to render metrics\n";
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const options = (try parseCommand(init)) orelse {
        try printHelp(init);
        return;
    };
    const allocator = init.arena.allocator();
    switch (options.command) {
        .run => try run(init, allocator, options),
        .config_check => {
            const loaded = try loadConfiguration(init, allocator, options);
            try validateConfig(&loaded.config);
            try validateSqliteAccess(allocator, loaded.config.db_path);
            common.log(.INFO, "configuration check passed", .{});
            logConfiguration(&loaded.config, false);
        },
        .api_test => {
            try runApiTest(init, allocator, options);
        },
        .api_worker => try runApiWorker(init, options.worker_fd orelse return error.MissingWorkerFd),
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
    const status_response = try apiGet(&runtime, allocator, "/service/status");
    const Status = struct { status: ?[]const u8 = null };
    const status = try std.json.parseFromSlice(Status, allocator, status_response, .{ .ignore_unknown_fields = true });
    defer status.deinit();
    if (status.value.status == null or !std.ascii.eqlIgnoreCase(status.value.status.?, "running")) return error.UnboundNotRunning;
    common.log(.INFO, "OPNsense Unbound service is running", .{});
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
    try prometheus.initialize(allocator, init.io);
    var metrics_server: ?PrometheusServer = if (runtime.config.metrics_enabled) try PrometheusServer.init(init, allocator, &runtime.config) else null;
    defer if (metrics_server) |*server| server.deinit();
    const unix_mode = std.mem.eql(u8, runtime.config.listen_type, "unix");
    const fd = if (unix_mode) try listenUnix(runtime.config.socket_path) else if (std.mem.eql(u8, runtime.config.listen_type, "tcp")) try listenTcp(runtime.config.tcp_host, runtime.config.tcp_port) else return error.InvalidListenType;
    defer _ = c.close(fd);
    defer if (unix_mode) std.Io.Dir.cwd().deleteFile(init.io, runtime.config.socket_path) catch {};
    _ = c.signal(c.SIGUSR1, onSigusr1);
    _ = c.signal(c.SIGUSR2, onSigusr2);
    _ = c.signal(c.SIGTERM, onShutdown);
    _ = c.signal(c.SIGINT, onShutdown);
    common.log(.INFO, "leaselinkd v{s} starting; architecture={s}; loglevel={s}", .{ common.version, @tagName(builtin.cpu.arch), @tagName(common.logLevel()) });
    common.log(.INFO, "listening via {s}", .{runtime.config.listen_type});
    if (runtime.config.metrics_enabled) common.log(.INFO, "Prometheus metrics listening on http://{s}:{d}/metrics", .{ runtime.config.metrics_host, runtime.config.metrics_port });
    logConfiguration(&runtime.config, false);
    healthCheck(&runtime, true);
    reconcile(&runtime) catch |err| common.log(.WARN, "startup OPNsense reconciliation failed: {t}", .{err});
    runtime.reconcile_due = nowSeconds() + runtime.config.reconcile_seconds;
    validateDnsState(&runtime);
    while (true) {
        if (shutdown_requested.load(.acquire) != 0) {
            common.log(.INFO, "shutdown requested; durable work remains in SQLite for the next start", .{});
            return;
        }
        var ready = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const result = c.poll(&ready, 1, 250);
        if (result > 0 and (ready.revents & c.POLLIN) != 0) {
            var accepted: usize = 0;
            while (accepted < max_accepts_per_iteration) : (accepted += 1) {
                const client = c.accept(fd, .{ .__sockaddr__ = null }, null);
                if (client >= 0) {
                    if (!setNonBlocking(client)) {
                        _ = c.close(client);
                        continue;
                    }
                    processConnection(client, &runtime) catch |err| common.log(.ERROR, "lease event failed: {t}", .{err});
                    _ = c.close(client);
                } else break;
            }
        }
        if (report_requested.swap(0, .acq_rel) != 0) {
            logConfiguration(&runtime.config, false);
            logMetrics(&runtime);
        }
        if (resync_requested.swap(0, .acq_rel) != 0) {
            forceResync(&runtime);
        }
        serviceTimers(&runtime);
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
        } else if (std.mem.eql(u8, args[i], "--api-worker-fd")) {
            i += 1;
            if (i == args.len or options.command != .run) return error.ConflictingCommand;
            options.worker_fd = std.fmt.parseInt(c_int, args[i], 10) catch return error.InvalidWorkerFd;
            options.command = .api_worker;
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
        \\  --loglevel <LEVEL>       Logging level: ERROR, WARN, INFO, DEBUG, or TRACE. [default: INFO]
        \\  -h, --help               Show this message and exit.
        \\
        \\The manager listens using /etc/leaselinkd/config.json. --api-test has a 60-second
        \\overall deadline; every OPNsense API request has a five-second deadline.
        \\
    );
    try output.interface.flush();
}
fn validateConfig(config: *const Config) !void {
    const https = std.mem.startsWith(u8, config.opnsense_url, "https://");
    const http = std.mem.startsWith(u8, config.opnsense_url, "http://");
    if (!https and !http) return error.InvalidOpnsenseUrl;
    if (http and !config.allow_insecure_http) return error.InsecureHttpDisabled;
    if (config.record_ttl_seconds <= 0 or config.reconcile_seconds <= 0 or config.queue_max_events == 0 or config.queue_max_events > max_pending_events or config.throttle_seconds < 0 or config.health_check_seconds <= 0 or config.initial_backoff_ms <= 0 or config.max_backoff_ms < config.initial_backoff_ms or config.api_timeout_seconds <= 0 or config.api_timeout_seconds > 3600 or config.api_test_timeout_seconds <= 0 or config.api_test_timeout_seconds > 3600 or config.metrics_port == 0) return error.InvalidTimerConfiguration;
    if (!std.mem.eql(u8, config.metrics_host, "127.0.0.1") and !std.mem.eql(u8, config.metrics_host, "0.0.0.0")) return error.InvalidMetricsHost;
    if (std.mem.eql(u8, config.listen_type, "unix")) {
        if (config.socket_path.len == 0 or config.socket_path.len >= 108) return error.InvalidSocketPath;
    } else if (std.mem.eql(u8, config.listen_type, "tcp")) {
        if (!std.mem.eql(u8, config.tcp_host, "127.0.0.1") or config.tcp_port == 0) return error.InsecureTcpConfiguration;
    } else return error.InvalidListenType;
    for (config.dns_servers) |server| _ = try dnsServerAddress(server);
}
fn onSigusr1(_: c_int) callconv(.c) void {
    report_requested.store(1, .release);
}
fn onSigusr2(_: c_int) callconv(.c) void {
    resync_requested.store(1, .release);
}
fn onShutdown(_: c_int) callconv(.c) void {
    shutdown_requested.store(1, .release);
}
fn logConfiguration(config: *const Config, debug: bool) void {
    if (debug) common.log(.DEBUG, "config: api={s}, listener={s}, socket={s}, tcp={s}:{d}, metrics={s}:{d}, domain={s}, throttle={d}s, health={d}s, api_timeout={d}s, api_test_timeout={d}s", .{ config.opnsense_url, config.listen_type, config.socket_path, config.tcp_host, config.tcp_port, config.metrics_host, config.metrics_port, config.domain, config.throttle_seconds, config.health_check_seconds, config.api_timeout_seconds, config.api_test_timeout_seconds }) else common.log(.INFO, "config: api={s}, listener={s}, socket={s}, tcp={s}:{d}, metrics={s}:{d}, domain={s}, throttle={d}s, health={d}s, api_timeout={d}s, api_test_timeout={d}s", .{ config.opnsense_url, config.listen_type, config.socket_path, config.tcp_host, config.tcp_port, config.metrics_host, config.metrics_port, config.domain, config.throttle_seconds, config.health_check_seconds, config.api_timeout_seconds, config.api_test_timeout_seconds });
}
fn logMetrics(r: *const Runtime) void {
    common.log(.INFO, "metrics: runtime={d}s lease_events={d} api_calls={d} get={d} post={d} api_failures={d} health_checks={d} health_failures={d} reconfigures={d}", .{ nowSeconds() - r.started_at, r.lease_events, r.api_calls, r.api_get_calls, r.api_post_calls, r.api_failures, r.health_checks, r.health_failures, r.reconfigures });
}
fn loadRuntime(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions) !Runtime {
    const loaded = try loadConfiguration(init, allocator, options);
    const db_path = try allocator.dupeZ(u8, loaded.config.db_path);
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(db_path.ptr, &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    errdefer _ = c.sqlite3_close(db);
    try sql(db.?, "PRAGMA journal_mode=WAL;");
    try sql(db.?, "CREATE TABLE IF NOT EXISTS overrides (hostname TEXT PRIMARY KEY, uuid TEXT NOT NULL, ip_address TEXT NOT NULL);");
    try sql(db.?, "CREATE TABLE IF NOT EXISTS desired_overrides (hostname TEXT PRIMARY KEY, owner_id TEXT NOT NULL, ip_address TEXT NOT NULL, present INTEGER NOT NULL, expires_at INTEGER NOT NULL, uuid TEXT, dirty INTEGER NOT NULL DEFAULT 1, next_attempt INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0);");
    return .{ .config = loaded.config, .key = loaded.key, .secret = loaded.secret, .db = db.?, .io = init.io, .started_at = nowSeconds(), .health_backoff_ms = loaded.config.initial_backoff_ms, .reconcile_due = nowSeconds() };
}
fn loadConfiguration(init: std.process.Init, allocator: std.mem.Allocator, options: CommandOptions) !LoadedConfiguration {
    const config_path = options.config_path orelse init.minimal.environ.getPosix("LEASELINKD_CONFIG") orelse "/etc/leaselinkd/config.json";
    const secrets_path = options.secrets_path orelse init.minimal.environ.getPosix("LEASELINKD_SECRETS") orelse "/etc/leaselinkd/secrets.json";
    const cb = try std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .limited(128 * 1024));
    const sb = try std.Io.Dir.cwd().readFileAlloc(init.io, secrets_path, allocator, .limited(128 * 1024));
    const config = try std.json.parseFromSliceLeaky(Config, allocator, cb, .{ .ignore_unknown_fields = true });
    if (!options.loglevel_set) if (config.loglevel) |level| try common.setLogLevel(level);
    const secrets = try std.json.parseFromSliceLeaky(Secrets, allocator, sb, .{ .ignore_unknown_fields = true });
    const key = secrets.api_key orelse secrets.apik_key orelse return error.MissingApiKey;
    const secret = secrets.api_secret orelse secrets.apikey_secret orelse return error.MissingApiSecret;
    return .{ .config = config, .key = key, .secret = secret };
}
fn validateSqliteAccess(allocator: std.mem.Allocator, db_path: []const u8) !void {
    const db_path_z = try allocator.dupeZ(u8, db_path);
    const directory = if (std.mem.lastIndexOfScalar(u8, db_path, '/')) |separator|
        if (separator == 0) "/" else db_path[0..separator]
    else
        ".";
    const directory_z = try allocator.dupeZ(u8, directory);
    if (c.access(directory_z.ptr, c.W_OK | c.X_OK) != 0) return error.SqliteDirectoryAccessFailed;
    if (c.access(db_path_z.ptr, c.F_OK) != 0) return;
    if (c.access(db_path_z.ptr, c.R_OK | c.W_OK) != 0) return error.SqliteFileAccessFailed;
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(db_path_z.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        if (db) |opened| _ = c.sqlite3_close(opened);
        return error.SqliteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);
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
    if (c.bind(fd, .{ .__sockaddr_un__ = &addr }, @intCast(len)) != 0 or c.chmod(&path_z, 0o660) != 0 or c.listen(fd, max_pending_events) != 0 or c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK) < 0) return error.BindFailed;
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
    defer std.heap.page_allocator.free(host_z);
    if (c.inet_pton(c.AF_INET, host_z.ptr, &addr.sin_addr) != 1) return error.InvalidTcpHost;
    if (c.bind(fd, .{ .__sockaddr_in__ = &addr }, @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(fd, max_pending_events) != 0 or c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK) < 0) return error.BindFailed;
    return fd;
}
fn setNonBlocking(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFL);
    return flags >= 0 and c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) >= 0;
}
fn nowSeconds() i64 {
    return @intCast(c.time(null));
}
const DnsAnswer = struct { addresses: usize = 0, matches: bool = false, rcode: u4 = 0, first_address: ?[4]u8 = null };
fn dnsServerAddress(server: []const u8) !c.struct_sockaddr_in {
    var host = server;
    var port: u16 = 53;
    if (std.mem.lastIndexOfScalar(u8, server, ':')) |at| {
        host = server[0..at];
        port = std.fmt.parseInt(u16, server[at + 1 ..], 10) catch return error.InvalidDnsServer;
    }
    if (host.len == 0 or port == 0) return error.InvalidDnsServer;
    const host_z = try std.heap.page_allocator.dupeZ(u8, host);
    defer std.heap.page_allocator.free(host_z);
    var address = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_port = c.htons(port);
    if (c.inet_pton(c.AF_INET, host_z.ptr, &address.sin_addr) != 1) return error.InvalidDnsServer;
    return address;
}
fn writeDnsName(buffer: []u8, index: *usize, name: []const u8) !void {
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63 or index.* + label.len + 1 > buffer.len) return error.InvalidDnsName;
        buffer[index.*] = @intCast(label.len);
        index.* += 1;
        @memcpy(buffer[index.* .. index.* + label.len], label);
        index.* += label.len;
    }
    if (index.* >= buffer.len) return error.InvalidDnsName;
    buffer[index.*] = 0;
    index.* += 1;
}
fn skipDnsName(buffer: []const u8, index: *usize) !void {
    while (true) {
        if (index.* >= buffer.len) return error.InvalidDnsReply;
        const length = buffer[index.*];
        if (length & 0xc0 == 0xc0) {
            if (index.* + 1 >= buffer.len) return error.InvalidDnsReply;
            index.* += 2;
            return;
        }
        index.* += 1;
        if (length == 0) return;
        if (length > 63 or index.* + length > buffer.len) return error.InvalidDnsReply;
        index.* += length;
    }
}
fn readU16(buffer: []const u8, index: *usize) !u16 {
    if (index.* + 2 > buffer.len) return error.InvalidDnsReply;
    const value = (@as(u16, buffer[index.*]) << 8) | buffer[index.* + 1];
    index.* += 2;
    return value;
}
fn buildDnsQuery(query: []u8, id: u16, hostname: []const u8, domain: []const u8) !usize {
    if (query.len < 12) return error.InvalidDnsQuery;
    @memset(query, 0);
    query[0] = @truncate(id >> 8);
    query[1] = @truncate(id);
    query[2] = 1; // recursion desired
    query[5] = 1; // QDCOUNT: one question follows the DNS header
    var query_len: usize = 12;
    var fullname: [255]u8 = undefined;
    const name = std.fmt.bufPrint(&fullname, "{s}.{s}", .{ hostname, domain }) catch return error.InvalidDnsName;
    try writeDnsName(query, &query_len, name);
    if (query_len + 4 > query.len) return error.InvalidDnsName;
    query[query_len] = 0;
    query_len += 1;
    query[query_len] = 1;
    query_len += 1;
    query[query_len] = 0;
    query_len += 1;
    query[query_len] = 1;
    query_len += 1;
    return query_len;
}
fn parseDnsReply(query: []const u8, bytes: []const u8, wanted: [4]u8) !DnsAnswer {
    if (query.len < 2 or bytes.len < 12) return error.InvalidDnsReply;
    if (bytes[0] != query[0] or bytes[1] != query[1]) return error.DnsLookupFailed;
    var index: usize = 4;
    const questions = try readU16(bytes, &index);
    const answers = try readU16(bytes, &index);
    index = 12;
    for (0..questions) |_| {
        try skipDnsName(bytes, &index);
        index += 4;
        if (index > bytes.len) return error.InvalidDnsReply;
    }
    var result = DnsAnswer{ .rcode = @truncate(bytes[3] & 0x0f) };
    if (result.rcode != 0) return result;
    for (0..answers) |_| {
        try skipDnsName(bytes, &index);
        const record_type = try readU16(bytes, &index);
        const record_class = try readU16(bytes, &index);
        if (index + 6 > bytes.len) return error.InvalidDnsReply;
        index += 4;
        const length = try readU16(bytes, &index);
        if (index + length > bytes.len) return error.InvalidDnsReply;
        if (record_type == 1 and record_class == 1 and length == 4) {
            result.addresses += 1;
            if (result.first_address == null) result.first_address = bytes[index..][0..4].*;
            if (std.mem.eql(u8, bytes[index .. index + 4], &wanted)) result.matches = true;
        }
        index += length;
    }
    return result;
}
fn dnsLookup(server: []const u8, hostname: []const u8, domain: []const u8, ip: []const u8) !DnsAnswer {
    const address = try dnsServerAddress(server);
    var wanted: [4]u8 = undefined;
    const ip_z = try std.heap.page_allocator.dupeZ(u8, ip);
    defer std.heap.page_allocator.free(ip_z);
    if (c.inet_pton(c.AF_INET, ip_z.ptr, &wanted) != 1) return error.InvalidLeaseAddress;
    var query: [512]u8 = undefined;
    const id: u16 = @truncate(@as(u64, @intCast(nowSeconds())));
    const query_len = try buildDnsQuery(&query, id, hostname, domain);
    const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
    if (fd < 0) return error.DnsSocketFailed;
    defer _ = c.close(fd);
    if (c.sendto(fd, &query, query_len, 0, .{ .__sockaddr_in__ = &address }, @sizeOf(c.struct_sockaddr_in)) < 0) return error.DnsSendFailed;
    var ready = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&ready, 1, 2000) <= 0) return error.DnsTimeout;
    var reply: [2048]u8 = undefined;
    const received = c.recv(fd, &reply, reply.len, 0);
    if (received < 12) return error.InvalidDnsReply;
    const bytes = reply[0..@intCast(received)];
    return parseDnsReply(query[0..query_len], bytes, wanted);
}
test "DNS resolver builds one valid A question" {
    var query: [512]u8 = undefined;
    const query_len = try buildDnsQuery(&query, 0x1234, "ranos", "ashbyte.com");
    try std.testing.expectEqual(@as(usize, 35), query_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x01, 0x00, 0x00, 0x01 }, query[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x00, 0x01 }, query[query_len - 4 .. query_len]);
}
test "DNS resolver parses matching A response" {
    var query: [512]u8 = undefined;
    const query_len = try buildDnsQuery(&query, 0x1234, "ranos", "ashbyte.com");
    var reply: [512]u8 = undefined;
    @memcpy(reply[0..query_len], query[0..query_len]);
    reply[2] = 0x81;
    reply[3] = 0x80;
    reply[6] = 0;
    reply[7] = 1;
    var index = query_len;
    const answer = [_]u8{ 0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x00, 0x04, 10, 12, 1, 81 };
    @memcpy(reply[index .. index + answer.len], &answer);
    index += answer.len;
    const parsed = try parseDnsReply(query[0..query_len], reply[0..index], .{ 10, 12, 1, 81 });
    try std.testing.expectEqual(@as(u4, 0), parsed.rcode);
    try std.testing.expectEqual(@as(usize, 1), parsed.addresses);
    try std.testing.expect(parsed.matches);
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 12, 1, 81 }), parsed.first_address);
}
test "DNS resolver reports NXDOMAIN and FORMERR" {
    var query: [512]u8 = undefined;
    const query_len = try buildDnsQuery(&query, 0x1234, "cat", "ashbyte.com");
    var reply: [512]u8 = undefined;
    @memcpy(reply[0..query_len], query[0..query_len]);
    reply[2] = 0x81;
    reply[3] = 0x83;
    const nxdomain = try parseDnsReply(query[0..query_len], reply[0..query_len], .{ 10, 12, 1, 81 });
    try std.testing.expectEqual(@as(u4, 3), nxdomain.rcode);
    reply[3] = 0x81;
    const formerr = try parseDnsReply(query[0..query_len], reply[0..query_len], .{ 10, 12, 1, 81 });
    try std.testing.expectEqual(@as(u4, 1), formerr.rcode);
}
test "DNS resolver rejects truncated replies" {
    var query: [512]u8 = undefined;
    const query_len = try buildDnsQuery(&query, 0x1234, "ranos", "ashbyte.com");
    var reply: [12]u8 = [_]u8{0} ** 12;
    reply[0] = query[0];
    reply[1] = query[1];
    reply[5] = 1;
    try std.testing.expectError(error.InvalidDnsReply, parseDnsReply(query[0..query_len], &reply, .{ 10, 12, 1, 81 }));
}

test "lease Content-Length parsing rejects ambiguous and unsafe framing" {
    try std.testing.expectEqual(@as(?usize, 0), headerContentLength("POST /lease_event HTTP/1.1\r\ncontent-length: 0"));
    try std.testing.expectEqual(@as(?usize, 12), headerContentLength("POST /lease_event HTTP/1.1\r\nContent-Length: 12"));
    try std.testing.expect(headerContentLength("POST /lease_event HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1") == null);
    try std.testing.expect(headerContentLength("POST /lease_event HTTP/1.1\r\nTransfer-Encoding: chunked") == null);
    try std.testing.expect(headerContentLength("POST /lease_event HTTP/1.1\r\nContent-Length: 18446744073709551616") == null);
}

test "production transport policy requires HTTPS and loopback TCP" {
    const http = Config{ .opnsense_url = "http://127.0.0.1/api/unbound" };
    try std.testing.expectError(error.InsecureHttpDisabled, validateConfig(&http));
    const insecure_loopback = Config{ .opnsense_url = "http://127.0.0.1/api/unbound", .allow_insecure_http = true };
    try validateConfig(&insecure_loopback);
    const remote_tcp = Config{ .opnsense_url = "https://opnsense.example/api/unbound", .listen_type = "tcp", .tcp_host = "0.0.0.0" };
    try std.testing.expectError(error.InsecureTcpConfiguration, validateConfig(&remote_tcp));
}
fn validateDnsRecord(r: *Runtime, hostname: []const u8, ip: []const u8, startup: bool) !bool {
    var matches = false;
    var fullname_buffer: [255]u8 = undefined;
    const fullname = std.fmt.bufPrint(&fullname_buffer, "{s}.{s}", .{ hostname, r.config.domain }) catch hostname;
    for (r.config.dns_servers) |server| {
        const answer = dnsLookup(server, hostname, r.config.domain, ip) catch |err| {
            if (startup) common.log(.ERROR, "DNS validation failed: server={s} host={s} fqdn={s} expected_ip={s} error={t}", .{ server, hostname, fullname, ip, err }) else common.log(.WARN, "DNS lookup failed before update: server={s} host={s} fqdn={s} expected_ip={s} error={t}", .{ server, hostname, fullname, ip, err });
            continue;
        };
        if (answer.rcode != 0) {
            if (startup) common.log(.ERROR, "DNS response error: server={s} host={s} fqdn={s} expected_ip={s} rcode={d}", .{ server, hostname, fullname, ip, answer.rcode }) else common.log(.WARN, "DNS response error: server={s} host={s} fqdn={s} expected_ip={s} rcode={d}", .{ server, hostname, fullname, ip, answer.rcode });
            continue;
        }
        if (answer.addresses > 1) common.log(.WARN, "DNS validation found multiple A records: server={s} host={s} count={d}", .{ server, hostname, answer.addresses });
        if (!answer.matches) {
            if (answer.first_address) |observed| {
                if (startup) common.log(.ERROR, "DNS validation mismatch: server={s} host={s} fqdn={s} expected_ip={s} observed_ip={d}.{d}.{d}.{d}", .{ server, hostname, fullname, ip, observed[0], observed[1], observed[2], observed[3] }) else common.log(.INFO, "DNS validation mismatch: server={s} host={s} fqdn={s} expected_ip={s} observed_ip={d}.{d}.{d}.{d}", .{ server, hostname, fullname, ip, observed[0], observed[1], observed[2], observed[3] });
            } else {
                if (startup) common.log(.ERROR, "DNS validation missing A record: server={s} host={s} fqdn={s} expected_ip={s}", .{ server, hostname, fullname, ip }) else common.log(.INFO, "DNS validation missing A record: server={s} host={s} fqdn={s} expected_ip={s}", .{ server, hostname, fullname, ip });
            }
        }
        matches = matches or answer.matches;
    }
    return matches;
}
fn validateDnsState(r: *Runtime) void {
    if (r.config.dns_servers.len == 0) return common.log(.WARN, "DNS validation skipped: dns_servers is empty", .{});
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(r.db, "SELECT hostname,ip_address FROM desired_overrides WHERE present=1", -1, &stmt, null) != c.SQLITE_OK) return common.log(.ERROR, "DNS validation could not read SQLite desired state", .{});
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const hostname = std.mem.span(c.sqlite3_column_text(stmt, 0));
        const ip = std.mem.span(c.sqlite3_column_text(stmt, 1));
        const matches = validateDnsRecord(r, hostname, ip, true) catch false;
        if (!matches) {
            queueDesired(r.db, hostname) catch |err| {
                common.log(.ERROR, "DNS validation could not queue update: host={s} error={t}", .{ hostname, err });
                continue;
            };
            common.log(.INFO, "DNS validation queued OPNsense update: host={s} ip={s}", .{ hostname, ip });
        }
    }
}
fn serviceTimers(r: *Runtime) void {
    expireDesired(r) catch |err| common.log(.ERROR, "TTL cleanup failed: {t}", .{err});
    var work_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer work_arena.deinit();
    const allocator = work_arena.allocator();
    const now = nowSeconds();
    // Service time-based operations before one durable item. A continuously
    // dirty queue must not prevent health checks or deferred reconfiguration.
    if (now >= r.health_due) healthCheckWithAllocator(r, allocator, false);
    if (now >= r.reconcile_due) {
        common.log(.TRACE, "reconciliation work arena begin", .{});
        reconcileWithAllocator(r, allocator) catch |err| common.log(.WARN, "OPNsense reconciliation failed: {t}", .{err});
        common.log(.TRACE, "reconciliation work arena release", .{});
        r.reconcile_due = now + r.config.reconcile_seconds;
    }
    if (r.reconfigure_due) |due| if (now >= due) {
        common.log(.TRACE, "reconfigure work arena begin", .{});
        common.log(.INFO, "calling Unbound reconfigure", .{});
        _ = apiPost(r, allocator, "/service/reconfigure", "{}") catch |err| {
            common.log(.ERROR, "Unbound reconfigure failed: {t}", .{err});
            r.reconfigure_due = now + 1;
            common.log(.TRACE, "reconfigure work arena release after failure", .{});
            return serviceOneDesired(r, allocator, now);
        };
        r.reconfigures += 1;
        prometheus.reconfigured();
        r.reconfigure_due = null;
        common.log(.TRACE, "reconfigure work arena release", .{});
    };
    serviceOneDesired(r, allocator, now);
}
fn serviceOneDesired(r: *Runtime, allocator: std.mem.Allocator, now: i64) void {
    const due_work = nextDesired(r.db, allocator, now) catch |err| {
        common.log(.ERROR, "durable work lookup failed: {t}", .{err});
        return;
    };
    if (due_work) |desired| {
        common.log(.TRACE, "timer work arena begin: host={s} present={} ip={s}", .{ desired.hostname, desired.present, desired.ip });
        processDesired(r, allocator, desired) catch |err| {
            scheduleRetry(r.db, desired.hostname) catch |db_err| common.log(.ERROR, "durable retry scheduling failed: {t}", .{db_err});
            common.log(.WARN, "durable lease work failed: {t}", .{err});
        };
        common.log(.TRACE, "timer work arena release: host={s}", .{desired.hostname});
    }
}
fn forceResync(r: *Runtime) void {
    common.log(.INFO, "SIGUSR2 requested SQLite-to-OPNsense resync", .{});
    reconcile(r) catch |err| {
        common.log(.WARN, "requested OPNsense resync failed: {t}", .{err});
        return;
    };
    r.reconcile_due = nowSeconds() + r.config.reconcile_seconds;
    common.log(.INFO, "requested SQLite-to-OPNsense resync queued durable records", .{});
}
fn requestReconfigure(r: *Runtime) void {
    const due = nowSeconds() + @max(@as(i64, 0), r.config.throttle_seconds);
    r.reconfigure_due = if (r.reconfigure_due) |existing| @min(existing, due) else due;
    common.log(.DEBUG, "reconfigure scheduled for {d}", .{r.reconfigure_due.?});
}
fn healthCheck(r: *Runtime, startup: bool) void {
    var work_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer common.log(.TRACE, "health-check arena released: startup={}", .{startup});
    defer work_arena.deinit();
    common.log(.TRACE, "health-check arena begin: startup={}", .{startup});
    healthCheckWithAllocator(r, work_arena.allocator(), startup);
}
fn healthCheckWithAllocator(r: *Runtime, allocator: std.mem.Allocator, startup: bool) void {
    r.health_checks += 1;
    prometheus.healthCheck();
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
        prometheus.healthFailure();
        const delay = @max(@as(i64, 1), @divTrunc(r.health_backoff_ms + 999, 1000));
        common.log(.WARN, "OPNsense health check failed: {t}; retrying in {d}s", .{ err, delay });
        r.health_due = nowSeconds() + delay;
        r.health_backoff_ms = @min(r.health_backoff_ms * 2, r.config.max_backoff_ms);
    }
}
fn processConnection(fd: c_int, r: *Runtime) !void {
    var work_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const started = monotonicMilliseconds();
    defer common.log(.TRACE, "lease request arena released: elapsed_ms={d}", .{monotonicMilliseconds() - started});
    defer prometheus.leaseRequestDuration(@intCast(@max(@as(i64, 0), monotonicMilliseconds() - started)));
    defer work_arena.deinit();
    const allocator = work_arena.allocator();
    common.log(.TRACE, "lease request arena begin", .{});
    var buffer: [65536]u8 = undefined;
    var total: usize = 0;
    const deadline = monotonicMilliseconds() + lease_request_timeout_ms;
    while (total < buffer.len) {
        const raw = c.recv(fd, buffer[total..].ptr, buffer.len - total, 0);
        if (raw == 0) return;
        if (raw < 0) switch (std.posix.errno(raw)) {
            .AGAIN => waitFd(fd, c.POLLIN, deadline) catch |err| switch (err) {
                error.ApiTimeout => {
                    prometheus.leaseRejected();
                    return respond(fd, 408);
                },
                else => return err,
            },
            .INTR => continue,
            else => return error.ReceiveFailed,
        };
        if (raw < 0) continue;
        total += @intCast(raw);
        const request = buffer[0..total];
        const at = std.mem.indexOf(u8, request, "\r\n\r\n") orelse continue;
        const content_length = headerContentLength(request[0..at]) orelse {
            common.log(.WARN, "invalid HTTP headers", .{});
            prometheus.leaseRejected();
            return respond(fd, 400);
        };
        const body_start = std.math.add(usize, at, 4) catch {
            prometheus.leaseRejected();
            return respond(fd, 400);
        };
        if (content_length > buffer.len - body_start) {
            prometheus.leaseRejected();
            return respond(fd, 413);
        }
        const body_end = body_start + content_length;
        if (total < body_end) continue;
        if (!std.mem.startsWith(u8, request, "POST /lease_event ")) {
            prometheus.leaseRejected();
            return respond(fd, 404);
        }
        const event = std.json.parseFromSliceLeaky(common.Event, allocator, request[body_start..body_end], .{ .ignore_unknown_fields = true }) catch |err| {
            common.log(.WARN, "invalid lease-event JSON: {t}", .{err});
            prometheus.leaseRejected();
            return respond(fd, 400);
        };
        if (common.leaseOperation(event.event) == null) {
            common.log(.WARN, "rejecting unsupported Kea hook point: {s}", .{event.event});
            prometheus.leaseRejected();
            return respond(fd, 422);
        }
        if (!common.validHostLabel(event.lease.hostname)) {
            common.log(.WARN, "ignoring invalid hostname in {s}", .{event.event});
            prometheus.leaseRejected();
            return respond(fd, 422);
        }
        if (!common.isRemovalEvent(event.event) and !common.validUnboundIpv4(event.lease.@"ip-address")) {
            common.log(.WARN, "ignoring invalid or loopback IPv4 lease address in {s}", .{event.event});
            prometheus.leaseRejected();
            return respond(fd, 422);
        }
        persistDesired(r, allocator, event) catch |err| {
            common.log(.ERROR, "persisting lease intent failed: {t}", .{err});
            prometheus.leaseRejected();
            return respond(fd, 503);
        };
        r.lease_events += 1;
        prometheus.leaseAccepted();
        common.log(.INFO, "persisted lease event={s} host={s} ip={s}", .{ event.event, event.lease.hostname, event.lease.@"ip-address" });
        return respond(fd, 202);
    }
    prometheus.leaseRejected();
    return respond(fd, 400);
}
fn headerContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return null;
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        if (content_length != null) return null;
        content_length = std.fmt.parseInt(usize, value, 10) catch return null;
    }
    return content_length;
}
fn respond(fd: c_int, code: u16) !void {
    const text = if (code == 202) "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n" else if (code == 404) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" else if (code == 408) "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\n\r\n" else if (code == 413) "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n" else if (code == 422) "HTTP/1.1 422 Unprocessable Content\r\nContent-Length: 0\r\n\r\n" else if (code == 503) "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" else "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    const deadline = monotonicMilliseconds() + 250;
    var offset: usize = 0;
    while (offset < text.len) {
        const written = c.send(fd, text[offset..].ptr, text.len - offset, c.MSG_NOSIGNAL);
        if (written > 0) {
            offset += @intCast(written);
            continue;
        }
        if (written < 0 and std.posix.errno(written) == .AGAIN) {
            try waitFd(fd, c.POLLOUT, deadline);
            continue;
        }
        if (written < 0 and std.posix.errno(written) == .INTR) continue;
        return error.SendFailed;
    }
}
fn persistDesired(r: *Runtime, allocator: std.mem.Allocator, event: common.Event) !void {
    const previous_ip = try desiredIpFor(r.db, allocator, event.lease.hostname);
    const owner = (try ownerFor(r.db, allocator, event.lease.hostname)) orelse try newOwnerId(r.io, allocator);
    const present = !common.isRemovalEvent(event.event);
    if (present) if (previous_ip) |old_ip| if (!std.mem.eql(u8, old_ip, event.lease.@"ip-address")) common.log(.INFO, "tracked lease IP changed: event={s} host={s} previous_ip={s} new_ip={s}", .{ event.event, event.lease.hostname, old_ip, event.lease.@"ip-address" });
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
fn desiredIpFor(db: *c.sqlite3, allocator: std.mem.Allocator, hostname: []const u8) !?[]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT ip_address FROM desired_overrides WHERE hostname=? AND present=1", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
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
    if (r.config.dns_servers.len > 0 and try validateDnsRecord(r, desired.hostname, desired.ip, false)) {
        common.log(.INFO, "lease update redundant: DNS already resolves host={s} ip={s}", .{ desired.hostname, desired.ip });
        try markClean(r.db, desired.hostname);
        return;
    }
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
fn markClean(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "UPDATE desired_overrides SET dirty=0,failures=0 WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn queueDesired(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "UPDATE desired_overrides SET dirty=1,next_attempt=0,failures=0 WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, hostname.ptr, @intCast(hostname.len), c.SQLITE_TRANSIENT);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailed;
}
fn scheduleRetry(db: *c.sqlite3, hostname: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "UPDATE desired_overrides SET dirty=1,failures=failures+1,next_attempt=strftime('%s','now') + MIN(300, 1 << MIN(8,failures)) WHERE hostname=?", -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailed;
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
fn reconcile(r: *Runtime) !void {
    var work_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer work_arena.deinit();
    return reconcileWithAllocator(r, work_arena.allocator());
}
fn reconcileWithAllocator(r: *Runtime, allocator: std.mem.Allocator) !void {
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
    const started = monotonicMilliseconds();
    const request_bytes = endpoint.len + if (body) |payload| payload.len else 0;
    const response = apiWithTimeout(r, allocator, method, endpoint, body) catch |err| {
        r.api_failures += 1;
        prometheus.apiRequest(@tagName(method), request_bytes, @intCast(@max(@as(i64, 0), monotonicMilliseconds() - started)), 0, false);
        return err;
    };
    common.log(.TRACE, "OPNsense {s} completed: endpoint={s} request_bytes={d} response_bytes={d}", .{ @tagName(method), endpoint, request_bytes, response.len });
    prometheus.apiRequest(@tagName(method), request_bytes, @intCast(@max(@as(i64, 0), monotonicMilliseconds() - started)), response.len, true);
    return response;
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
    var worker_response: ApiWorkerResponse = undefined;
    readFdUntil(runtime.api_worker_fd, std.mem.asBytes(&worker_response), deadline) catch |err| {
        stopApiWorker(runtime);
        return err;
    };
    const worker_succeeded = worker_response.response_len != api_worker_error and worker_response.response_len <= max_api_frame_bytes;
    prometheus.apiWorkerRequest(@tagName(method), worker_response.elapsed_ms, worker_succeeded);
    if (!worker_succeeded) {
        stopApiWorker(runtime);
        common.log(.WARN, "OPNsense request failed; for HTTPS certificate diagnostics, run /usr/share/leaselinkd/check-firewall-certificate.sh --host <firewall-host> --port <https-port>", .{});
        return error.OpnsenseRequestFailed;
    }
    const response = try allocator.alloc(u8, @intCast(worker_response.response_len));
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
    const self_path_z: [:0]const u8 = "/proc/self/exe";
    var fd_text: [16]u8 = undefined;
    const fd_text_z = try std.fmt.bufPrintZ(&fd_text, "{d}", .{3});
    var argv: [4]?[*:0]const u8 = .{ self_path_z.ptr, "--api-worker-fd", fd_text_z.ptr, null };
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) {
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
        return error.ApiWorkerSpawnFailed;
    }
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (c.posix_spawn_file_actions_addclose(&actions, sockets[0]) != 0 or
        (sockets[1] != 3 and c.posix_spawn_file_actions_adddup2(&actions, sockets[1], 3) != 0) or
        (sockets[1] != 3 and c.posix_spawn_file_actions_addclose(&actions, sockets[1]) != 0) or
        c.posix_spawn_file_actions_addclosefrom_np(&actions, 4) != 0)
    {
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
        return error.ApiWorkerSpawnFailed;
    }
    var empty_environment: [1]?[*:0]const u8 = .{null};
    var pid: c.pid_t = undefined;
    if (c.posix_spawn(&pid, self_path_z.ptr, &actions, null, @ptrCast(&argv), @ptrCast(&empty_environment)) != 0) {
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
        return error.ApiWorkerSpawnFailed;
    }
    _ = c.close(sockets[1]);
    r.api_worker_fd = sockets[0];
    r.api_worker_pid = pid;
    prometheus.apiWorkerStarted(pid);
    const deadline = monotonicMilliseconds() + r.config.api_timeout_seconds * 1000;
    const bootstrap = ApiWorkerBootstrap{ .url_len = @intCast(r.config.opnsense_url.len), .key_len = @intCast(r.key.len), .secret_len = @intCast(r.secret.len) };
    writeFdUntil(r.api_worker_fd, std.mem.asBytes(&bootstrap), deadline) catch |err| {
        stopApiWorker(r);
        return err;
    };
    writeFdUntil(r.api_worker_fd, r.config.opnsense_url, deadline) catch |err| {
        stopApiWorker(r);
        return err;
    };
    writeFdUntil(r.api_worker_fd, r.key, deadline) catch |err| {
        stopApiWorker(r);
        return err;
    };
    writeFdUntil(r.api_worker_fd, r.secret, deadline) catch |err| {
        stopApiWorker(r);
        return err;
    };
    var ready: u8 = 0;
    readFdUntil(r.api_worker_fd, std.mem.asBytes(&ready), deadline) catch |err| {
        stopApiWorker(r);
        return err;
    };
    if (ready != api_worker_ready) {
        stopApiWorker(r);
        return error.ApiWorkerBootstrapFailed;
    }
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
    prometheus.apiWorkerStopped();
}
fn runApiWorker(init: std.process.Init, fd: c_int) !void {
    var bootstrap: ApiWorkerBootstrap = undefined;
    try readFdExact(fd, std.mem.asBytes(&bootstrap));
    if (bootstrap.magic != 0x4c4c4150 or bootstrap.version != 1 or bootstrap.url_len > max_api_frame_bytes or bootstrap.key_len > max_api_frame_bytes or bootstrap.secret_len > max_api_frame_bytes) return error.InvalidWorkerBootstrap;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = WorkerConfiguration{ .opnsense_url = try allocator.alloc(u8, bootstrap.url_len), .key = try allocator.alloc(u8, bootstrap.key_len), .secret = try allocator.alloc(u8, bootstrap.secret_len) };
    try readFdExact(fd, configuration.opnsense_url);
    try readFdExact(fd, configuration.key);
    try readFdExact(fd, configuration.secret);
    try writeFdAll(fd, &.{api_worker_ready});
    common.log(.INFO, "OPNsense API worker bootstrap complete", .{});
    apiWorkerLoop(init.io, configuration, fd);
}
fn apiWorkerLoop(io: std.Io, configuration: WorkerConfiguration, fd: c_int) void {
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    while (true) {
        var header: ApiRequestHeader = undefined;
        readFdExact(fd, std.mem.asBytes(&header)) catch return;
        if (header.method > 1 or header.endpoint_len > max_api_frame_bytes or header.body_len > max_api_frame_bytes) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer common.log(.TRACE, "API worker request arena released", .{});
        defer arena.deinit();
        const allocator = arena.allocator();
        common.log(.TRACE, "API worker request arena begin: method={s} endpoint_bytes={d} body_bytes={d}", .{ if (header.method == 0) "GET" else "POST", header.endpoint_len, header.body_len });
        const endpoint = allocator.alloc(u8, header.endpoint_len) catch return;
        const body = allocator.alloc(u8, header.body_len) catch return;
        readFdExact(fd, endpoint) catch return;
        readFdExact(fd, body) catch return;
        const started = monotonicMilliseconds();
        const response = apiRequestWithClient(configuration, allocator, &client, if (header.method == 0) .GET else .POST, endpoint, if (header.body_len == 0) null else body) catch |err| {
            common.log(.DEBUG, "persistent OPNsense worker request failed: {t}", .{err});
            writeWorkerResponse(fd, null, @intCast(@max(@as(i64, 0), monotonicMilliseconds() - started))) catch return;
            continue;
        };
        writeWorkerResponse(fd, response, @intCast(@max(@as(i64, 0), monotonicMilliseconds() - started))) catch return;
        common.log(.TRACE, "API worker response written: response_bytes={d}", .{response.len});
    }
}
fn writeWorkerResponse(fd: c_int, response: ?[]const u8, elapsed_ms: u64) !void {
    var header = ApiWorkerResponse{ .response_len = if (response) |value| @intCast(value.len) else api_worker_error, .elapsed_ms = elapsed_ms };
    try writeFdAll(fd, std.mem.asBytes(&header));
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
fn apiRequestWithClient(configuration: WorkerConfiguration, allocator: std.mem.Allocator, client: *std.http.Client, method: std.http.Method, endpoint: []const u8, body: ?[]const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ configuration.opnsense_url, endpoint });
    const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ configuration.key, configuration.secret });
    const encoded_len = std.base64.standard.Encoder.calcSize(credentials.len);
    const authorization = try allocator.alloc(u8, "Basic ".len + encoded_len);
    @memcpy(authorization[0..6], "Basic ");
    _ = std.base64.standard.Encoder.encode(authorization[6..], credentials);
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();
    const result = try client.fetch(.{ .location = .{ .url = url }, .method = method, .payload = body, .headers = .{ .authorization = .{ .override = authorization } }, .extra_headers = if (body != null) &.{.{ .name = "content-type", .value = "application/json" }} else &.{}, .redirect_behavior = .not_allowed, .response_writer = &response.writer });
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
