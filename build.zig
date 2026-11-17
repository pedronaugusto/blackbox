const std = @import("std");

/// What a project that depends on blackbox builds: the `blackbox` module, which imports aegis and
/// almanac alone, and its two sinks, always declared: `blackbox_jsonl`, the JSON Lines sink over
/// strand, and `blackbox_chronicle`, the chronicle sink over chronicle and strand. strand and
/// chronicle are lazy dependencies: fetched for the sinks' imports, and compiled only where a
/// project imports a sink. The build takes no options. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = blackboxModule(b, b, target, optimize);
    // The chronicle sink writes each record as the JSON Lines sink does.
    const jsonl = b.addModule("blackbox_jsonl", sinkOptions(b, target, optimize, "src/jsonl.zig", module, null));
    const chronicle_sink = b.addModule("blackbox_chronicle", sinkOptions(b, target, optimize, "src/chronicle.zig", module, jsonl));
    // A lazy dependency not fetched yet adds no import: the build fetches it and configures again.
    if (b.dependencyLazy("strand", .{ .target = target, .optimize = optimize })) |strand| {
        jsonl.addImport("strand", strand.module("strand"));
    } else |err| std.log.debug("strand not fetched yet ({t}): the build fetches it and configures again", .{err});
    if (b.dependencyLazy("chronicle", .{ .target = target, .optimize = optimize })) |chronicle| {
        chronicle_sink.addImport("chronicle", chronicle.module("chronicle"));
    } else |err| std.log.debug("chronicle not fetched yet ({t}): the build fetches it and configures again", .{err});
}

/// A sink module's source and the imports it has before its lazy dependency's: blackbox, aegis,
/// almanac, and the JSON Lines sink for the chronicle sink.
fn sinkOptions(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, root: []const u8, blackbox: *std.Build.Module, jsonl: ?*std.Build.Module) std.Build.Module.CreateOptions {
    const base = [_]std.Build.Module.Import{
        .{ .name = "blackbox", .module = blackbox },
        .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "almanac", .module = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac") },
    };
    const imports = if (jsonl) |j| p.allocator.dupe(std.Build.Module.Import, &(base ++ [_]std.Build.Module.Import{.{ .name = "blackbox_jsonl", .module = j }})) else p.allocator.dupe(std.Build.Module.Import, &base);
    return .{ .root_source_file = p.path(root), .target = target, .optimize = optimize, .imports = imports catch @panic("OOM") };
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
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const almanac = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac");
    const blackbox = package.module("blackbox");
    const tests = b.addTest(.{
        .name = "blackbox-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aegis", .module = aegis },
                .{ .name = "almanac", .module = almanac },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    // The optional modules' tests and examples, over the modules as a project gets them; strand
    // and chronicle are fetched for them. Not there until fetched: asking for one ends this
    // configure pass, and the next has it.
    const strand = (p.dependencyLazy("strand", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    const chronicle = (p.dependencyLazy("chronicle", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    // The sinks as a project gets them.
    const jsonl = package.module("blackbox_jsonl");
    const chronicle_sink = package.module("blackbox_chronicle");
    const module_tests = [_]struct { name: []const u8, root: []const u8, imports: []const std.Build.Module.Import }{
        .{ .name = "blackbox-jsonl-tests", .root = "src/testing/jsonl_test.zig", .imports = &.{
            .{ .name = "blackbox", .module = blackbox },
            .{ .name = "blackbox_jsonl", .module = jsonl },
            .{ .name = "strand", .module = strand.module("strand") },
            .{ .name = "almanac", .module = almanac },
            .{ .name = "shakedown", .module = shakedown.module("shakedown") },
        } },
        .{ .name = "blackbox-chronicle-tests", .root = "src/testing/chronicle_test.zig", .imports = &.{
            .{ .name = "blackbox", .module = blackbox },
            .{ .name = "blackbox_chronicle", .module = chronicle_sink },
            .{ .name = "blackbox_jsonl", .module = jsonl },
            .{ .name = "chronicle", .module = chronicle.module("chronicle") },
            .{ .name = "strand", .module = strand.module("strand") },
        } },
    };
    for (module_tests) |t| {
        const compiled = b.addTest(.{
            .name = t.name,
            .filters = filters,
            .root_module = b.createModule(.{ .root_source_file = p.path(t.root), .target = target, .optimize = optimize, .imports = t.imports }),
        });
        test_step.dependOn(&b.addRunArtifact(compiled).step);
        check.dependOn(&compiled.step);
    }
    // The README's JSON Lines example, run as part of the tests, where it writes its file.
    const jsonl_example = b.addExecutable(.{
        .name = "jsonl",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/jsonl.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "blackbox", .module = blackbox }, .{ .name = "blackbox_jsonl", .module = jsonl } } }),
    });
    const run_jsonl_example = b.addRunArtifact(jsonl_example);
    run_jsonl_example.setCwd(p.path("."));
    test_step.dependOn(&run_jsonl_example.step);
    check.dependOn(&jsonl_example.step);
    // The README's chronicle example, run as part of the tests, where it keeps its journal.
    const chronicle_example = b.addExecutable(.{
        .name = "chronicle",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/chronicle.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "blackbox", .module = blackbox }, .{ .name = "blackbox_chronicle", .module = chronicle_sink } } }),
    });
    const run_chronicle_example = b.addRunArtifact(chronicle_example);
    run_chronicle_example.setCwd(p.path("."));
    test_step.dependOn(&run_chronicle_example.step);
    check.dependOn(&chronicle_example.step);
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
                        .{ .name = "aegis", .module = aegis },
                        .{ .name = "blackbox", .module = blackbox },
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
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "blackbox", .module = blackbox }} }),
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
    // A consumer in each configuration of ci/workflow.json: blackbox, almanac and aegis, strand
    // with an optional module, chronicle with the chronicle sink; nothing of blackbox's development.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "blackbox", .program = p.path("ci/consumer.zig"), .modules = &.{ "blackbox", "blackbox_jsonl", "blackbox_chronicle" }, .packages = &.{ p.dependency("aegis", .{ .target = target, .optimize = optimize }), p.dependency("almanac", .{ .target = target, .optimize = optimize }), strand, chronicle } });
}

/// What each case of src/testing/secret_rejected.zig is refused with.
const secret_rejections = [_][]const u8{
    "the field fields.key holds one",
    "the field fields.bytes holds one",
    "the field fields.config.key holds one",
    "the field fields.message.args.0 holds one",
};
