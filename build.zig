const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common = b.createModule(.{ .root_source_file = b.path("src/common.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize }).module("httpz");

    const manager_c = b.addTranslateC(.{ .root_source_file = b.path("src/c/leaselinkd.h"), .target = target, .optimize = optimize });
    manager_c.defineCMacro("_GNU_SOURCE", "1");
    manager_c.defineCMacro("_FORTIFY_SOURCE", "0");
    const manager_c_mod = manager_c.createModule();
    const hook_c = b.addTranslateC(.{ .root_source_file = b.path("src/c/kea_hook.h"), .target = target, .optimize = optimize });
    hook_c.defineCMacro("_FORTIFY_SOURCE", "0");

    const manager_imports: []const std.Build.Module.Import = &.{ .{ .name = "common", .module = common }, .{ .name = "metrics", .module = metrics }, .{ .name = "httpz", .module = httpz }, .{ .name = "c", .module = manager_c_mod } };
    const ubm = b.addExecutable(.{ .name = "leaselinkd", .root_module = b.createModule(.{ .root_source_file = b.path("src/leaselinkd/main.zig"), .target = target, .optimize = optimize, .imports = manager_imports, .link_libc = true }) });
    ubm.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(ubm);

    const kh = b.addExecutable(.{ .name = "kea-leaselink", .root_module = b.createModule(.{ .root_source_file = b.path("src/kea_hook/main.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "common", .module = common }, .{ .name = "c", .module = hook_c.createModule() } }, .link_libc = true }) });
    b.installArtifact(kh);

    const tests = b.addTest(.{ .root_module = common });
    const run_tests = b.addRunArtifact(tests);
    const resolver_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/leaselinkd/main.zig"), .target = target, .optimize = optimize, .imports = manager_imports, .link_libc = true }) });
    resolver_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_resolver_tests = b.addRunArtifact(resolver_tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_resolver_tests.step);
    const integration = b.addSystemCommand(&.{ "sh", "tests/integration.sh" });
    integration.has_side_effects = true;
    integration.addFileArg(ubm.getEmittedBin());
    integration.addFileArg(kh.getEmittedBin());
    test_step.dependOn(&integration.step);
}
