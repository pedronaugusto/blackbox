const std = @import("std");

/// What a project that depends on blackbox builds: the `blackbox` module, which imports aegis and
/// almanac alone. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = blackboxModule(b, b, target, optimize);
}

fn blackboxModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.addModule("blackbox", .{ .root_source_file = p.path("src/blackbox.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("almanac", p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac"));
    return module;
}

/// blackbox's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("blackbox", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "blackbox-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
                .{ .name = "almanac", .module = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac") },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    // A secret logged by accident does not compile.
    if (test_filter == null or std.mem.find(u8, "secret", test_filter.?) != null) {
        for (secret_rejections, 0..) |message, case| {
            const rejection_options = b.addOptions();
            rejection_options.addOption(usize, "case", case);
            const rejected = b.addObject(.{
                .name = b.fmt("secret-rejected-{d}", .{case}),
                .root_module = b.createModule(.{
                    .root_source_file = p.path("src/testing/secret_rejected.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
                        .{ .name = "blackbox", .module = package.module("blackbox") },
                    },
                }),
            });
            rejected.root_module.addOptions("rejection_options", rejection_options);
            rejected.expect_errors = .{ .contains = message };
            test_step.dependOn(&rejected.step);
            check.dependOn(&rejected.step);
        }
    }
    b.getInstallStep().dependOn(&tests.step);
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
    });
}

/// What each case of src/testing/secret_rejected.zig is refused with.
const secret_rejections = [_][]const u8{
    "the field fields.key holds one",
    "the field fields.bytes holds one",
    "the field fields.config.key holds one",
    "the field fields.message.args.0 holds one",
};
