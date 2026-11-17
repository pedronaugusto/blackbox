const std = @import("std");

/// What a project that depends on blackbox builds: the `blackbox` module, which imports aegis and
/// almanac alone, and with `.jsonl = true` `blackbox_jsonl`, the JSON Lines sink, which fetches
/// strand. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const jsonl = b.option(bool, "jsonl", "Build blackbox_jsonl, the JSON Lines sink (fetches strand)") orelse false;
    const module = blackboxModule(b, b, target, optimize, jsonl);
    if (!jsonl) return;
    // Not there until fetched: asking for it ends this configure pass, and the next has it.
    const strand = (b.dependencyLazy("strand", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    _ = b.addModule("blackbox_jsonl", jsonlOptions(b, target, optimize, module, strand));
}

/// The `blackbox_jsonl` module's sources and imports, as `build` adds it and `dev` tests it.
fn jsonlOptions(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, blackbox: *std.Build.Module, strand: *std.Build.Dependency) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = p.path("src/jsonl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = p.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "blackbox", .module = blackbox },
            .{ .name = "strand", .module = strand.module("strand") },
            .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            .{ .name = "almanac", .module = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac") },
        }) catch @panic("OOM"),
    };
}

fn blackboxModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, jsonl: bool) *std.Build.Module {
    const module = b.addModule("blackbox", .{ .root_source_file = p.path("src/blackbox.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("almanac", p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac"));
    module.addImport("blackbox_options", featureOptions(b, jsonl));
    return module;
}

/// `blackbox_options`, saying whether `blackbox_jsonl` was built: `blackbox.built_with`.
fn featureOptions(b: *std.Build, jsonl: bool) *std.Build.Module {
    const features = b.addOptions();
    features.addOption(bool, "jsonl", jsonl);
    return features.createModule();
}

/// blackbox's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    // A configuration's option (ci/workflow.json): the package is built with blackbox_jsonl or
    // without, as a project would build it. blackbox_jsonl's own tests below build it either way.
    const with_jsonl = b.option(bool, "jsonl", "Build the package with blackbox_jsonl, as a configuration checks it") orelse false;
    const package = b.dependency("blackbox", .{ .target = target, .optimize = optimize, .jsonl = with_jsonl });
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
                .{ .name = "blackbox_options", .module = featureOptions(b, with_jsonl) },
            },
        }),
    });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    // blackbox_jsonl's tests, over the module as a project gets it; strand is fetched for them.
    // Not there until fetched: asking for it ends this configure pass, and the next has it.
    const strand = (p.dependencyLazy("strand", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    const jsonl_module = b.createModule(jsonlOptions(p, target, optimize, package.module("blackbox"), strand));
    const jsonl_tests = b.addTest(.{
        .name = "blackbox-jsonl-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/testing/jsonl_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blackbox", .module = package.module("blackbox") },
                .{ .name = "blackbox_jsonl", .module = jsonl_module },
                .{ .name = "strand", .module = strand.module("strand") },
                .{ .name = "almanac", .module = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac") },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(jsonl_tests).step);
    check.dependOn(&jsonl_tests.step);
    // The README's JSON Lines example, run as part of the tests.
    const jsonl_example = b.addExecutable(.{
        .name = "jsonl",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/jsonl.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "blackbox", .module = package.module("blackbox") }, .{ .name = "blackbox_jsonl", .module = jsonl_module } } }),
    });
    const run_jsonl_example = b.addRunArtifact(jsonl_example);
    run_jsonl_example.setCwd(p.path("."));
    test_step.dependOn(&run_jsonl_example.step);
    check.dependOn(&jsonl_example.step);
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
    // The README's examples, run as part of the tests.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blackbox", .module = package.module("blackbox") }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
    });
    // A consumer in each configuration of ci/workflow.json: blackbox, almanac and aegis, and strand
    // with blackbox_jsonl; nothing of blackbox's development.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "blackbox", .program = p.path("ci/consumer.zig"), .packages = &.{ p.dependency("aegis", .{ .target = target, .optimize = optimize }), p.dependency("almanac", .{ .target = target, .optimize = optimize }), strand } });
}

/// What each case of src/testing/secret_rejected.zig is refused with.
const secret_rejections = [_][]const u8{
    "the field fields.key holds one",
    "the field fields.bytes holds one",
    "the field fields.config.key holds one",
    "the field fields.message.args.0 holds one",
};
