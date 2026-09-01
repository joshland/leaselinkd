const std = @import("std");
const m = @import("metrics");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/resource.h");
});

const Metrics = struct {
    lease_events: m.Counter(u64),
    lease_rejections: m.Counter(u64),
    lease_server_latency_ms: m.Histogram(u64, &.{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000 }),
    api_requests: ApiRequests,
    api_failures: ApiFailures,
    api_request_latency_ms: ApiLatency,
    api_request_bytes: ApiBytes,
    api_response_bytes: ApiBytes,
    reconfigures: m.Counter(u64),
    health_checks: m.Counter(u64),
    health_failures: m.Counter(u64),
    process_cpu_user_seconds: m.Gauge(f64),
    process_cpu_system_seconds: m.Gauge(f64),
    process_resident_memory_bytes: m.Gauge(u64),
    process_virtual_memory_bytes: m.Gauge(u64),

    const ApiRequests = m.CounterVec(u64, struct { method: []const u8 });
    const ApiFailures = m.CounterVec(u64, struct { method: []const u8 });
    const ApiLatency = m.HistogramVec(u64, struct { method: []const u8 }, &.{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000 });
    const ApiBytes = m.CounterVec(u64, struct { method: []const u8 });
};

var metrics = m.initializeNoop(Metrics);
pub fn initialize(allocator: std.mem.Allocator, io: std.Io) !void {
    metrics = .{
        .lease_events = m.Counter(u64).init("lease_events_total", .{ .help = "Accepted Kea lease events persisted to SQLite." }, .{ .prefix = "leaselinkd_" }),
        .lease_rejections = m.Counter(u64).init("lease_event_rejections_total", .{ .help = "Rejected lease-event requests." }, .{ .prefix = "leaselinkd_" }),
        .lease_server_latency_ms = m.Histogram(u64, &.{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000 }).init("lease_event_request_duration_milliseconds", .{ .help = "Lease-event API request duration in milliseconds." }, .{ .prefix = "leaselinkd_" }),
        .api_requests = try Metrics.ApiRequests.init(allocator, io, "opnsense_api_requests_total", .{ .help = "OPNsense API requests issued." }, .{ .prefix = "leaselinkd_" }),
        .api_failures = try Metrics.ApiFailures.init(allocator, io, "opnsense_api_failures_total", .{ .help = "Failed OPNsense API requests." }, .{ .prefix = "leaselinkd_" }),
        .api_request_latency_ms = try Metrics.ApiLatency.init(allocator, io, "opnsense_api_request_duration_milliseconds", .{ .help = "OPNsense API request duration in milliseconds." }, .{ .prefix = "leaselinkd_" }),
        .api_request_bytes = try Metrics.ApiBytes.init(allocator, io, "opnsense_api_request_bytes_total", .{ .help = "Bytes sent to the OPNsense API." }, .{ .prefix = "leaselinkd_" }),
        .api_response_bytes = try Metrics.ApiBytes.init(allocator, io, "opnsense_api_response_bytes_total", .{ .help = "Bytes received from the OPNsense API." }, .{ .prefix = "leaselinkd_" }),
        .reconfigures = m.Counter(u64).init("unbound_reconfigures_total", .{ .help = "Successful Unbound reconfigures." }, .{ .prefix = "leaselinkd_" }),
        .health_checks = m.Counter(u64).init("opnsense_health_checks_total", .{ .help = "OPNsense health checks." }, .{ .prefix = "leaselinkd_" }),
        .health_failures = m.Counter(u64).init("opnsense_health_failures_total", .{ .help = "Failed OPNsense health checks." }, .{ .prefix = "leaselinkd_" }),
        .process_cpu_user_seconds = m.Gauge(f64).init("process_cpu_user_seconds", .{ .help = "Process user CPU time in seconds." }, .{ .prefix = "leaselinkd_" }),
        .process_cpu_system_seconds = m.Gauge(f64).init("process_cpu_system_seconds", .{ .help = "Process system CPU time in seconds." }, .{ .prefix = "leaselinkd_" }),
        .process_resident_memory_bytes = m.Gauge(u64).init("process_resident_memory_bytes", .{ .help = "Current process resident memory in bytes." }, .{ .prefix = "leaselinkd_" }),
        .process_virtual_memory_bytes = m.Gauge(u64).init("process_virtual_memory_bytes", .{ .help = "Current process virtual memory in bytes." }, .{ .prefix = "leaselinkd_" }),
    };
}

pub fn leaseAccepted() void {
    metrics.lease_events.incr();
}
pub fn leaseRejected() void {
    metrics.lease_rejections.incr();
}
pub fn leaseRequestDuration(milliseconds: u64) void {
    metrics.lease_server_latency_ms.observe(milliseconds);
}
pub fn reconfigured() void {
    metrics.reconfigures.incr();
}
pub fn healthCheck() void {
    metrics.health_checks.incr();
}
pub fn healthFailure() void {
    metrics.health_failures.incr();
}

pub fn apiRequest(method: []const u8, request_bytes: usize, elapsed_ms: u64, response_bytes: usize, succeeded: bool) void {
    metrics.api_requests.incr(.{ .method = method }) catch {};
    metrics.api_request_bytes.incrBy(.{ .method = method }, @intCast(request_bytes)) catch {};
    metrics.api_response_bytes.incrBy(.{ .method = method }, @intCast(response_bytes)) catch {};
    metrics.api_request_latency_ms.observe(.{ .method = method }, elapsed_ms) catch {};
    if (!succeeded) metrics.api_failures.incr(.{ .method = method }) catch {};
}

pub fn write(writer: *std.Io.Writer) !void {
    sampleProcess();
    try m.write(&metrics, writer);
}

fn sampleProcess() void {
    var usage: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &usage) == 0) {
        metrics.process_cpu_user_seconds.set(seconds(usage.ru_utime));
        metrics.process_cpu_system_seconds.set(seconds(usage.ru_stime));
    }
    const statm_file = c.fopen("/proc/self/statm", "r") orelse return;
    defer _ = c.fclose(statm_file);
    var statm: [128]u8 = undefined;
    const read = c.fread(&statm, 1, statm.len, statm_file);
    if (read == 0) return;
    var fields = std.mem.tokenizeAny(u8, statm[0..read], " \n");
    const virtual_pages = std.fmt.parseInt(u64, fields.next() orelse return, 10) catch return;
    const resident_pages = std.fmt.parseInt(u64, fields.next() orelse return, 10) catch return;
    const page_size: u64 = std.heap.pageSize();
    metrics.process_virtual_memory_bytes.set(virtual_pages * page_size);
    metrics.process_resident_memory_bytes.set(resident_pages * page_size);
}

fn seconds(value: c.struct_timeval) f64 {
    return @as(f64, @floatFromInt(value.tv_sec)) + @as(f64, @floatFromInt(value.tv_usec)) / 1_000_000.0;
}
