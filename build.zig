const std = @import("std");

/// What a project that depends on blackbox builds: the `blackbox` module, which imports aegis and
/// almanac alone; with `.jsonl = true` `blackbox_jsonl`, the JSON Lines sink, which fetches strand;
/// with `.chronicle = true` `blackbox_chronicle`, the chronicle sink, which fetches chronicle and
/// strand. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features: Features = .{
        .jsonl = b.option(bool, "jsonl", "Build blackbox_jsonl, the JSON Lines sink (fetches strand)") orelse false,
        .chronicle = b.option(bool, "chronicle", "Build blackbox_chronicle, the chronicle sink (fetches chronicle and strand)") orelse false,
    };
    const module = blackboxModule(b, b, target, optimize, features);
    if (!features.jsonl and !features.chronicle) return;
    // Not there until fetched: asking for it ends this configure pass, and the next has it.
    const strand = (b.dependencyLazy("strand", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    // The chronicle sink writes each record as the JSON Lines sink does: without `.jsonl` it has
    // the renderer to itself, and the project gets no `blackbox_jsonl`.
    const options = jsonlOptions(b, target, optimize, module, strand);
    const jsonl = if (features.jsonl) b.addModule("blackbox_jsonl", options) else b.createModule(options);
    if (!features.chronicle) return;
    const chronicle = (b.dependencyLazy("chronicle", .{ .target = target, .optimize = optimize }) catch null) orelse return;
    _ = b.addModule("blackbox_chronicle", chronicleOptions(b, target, optimize, module, jsonl, chronicle));
}

/// Which of the optional modules a build makes.
const Features = struct { jsonl: bool, chronicle: bool };

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

/// The `blackbox_chronicle` module's sources and imports, as `build` adds it and `dev` tests it.
fn chronicleOptions(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, blackbox: *std.Build.Module, jsonl: *std.Build.Module, chronicle: *std.Build.Dependency) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = p.path("src/chronicle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = p.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "blackbox", .module = blackbox },
            .{ .name = "blackbox_jsonl", .module = jsonl },
            .{ .name = "chronicle", .module = chronicle.module("chronicle") },
            .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            .{ .name = "almanac", .module = p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac") },
        }) catch @panic("OOM"),
    };
}

fn blackboxModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, features: Features) *std.Build.Module {
    const module = b.addModule("blackbox", .{ .root_source_file = p.path("src/blackbox.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("almanac", p.dependency("almanac", .{ .target = target, .optimize = optimize }).module("almanac"));
    module.addImport("blackbox_options", featureOptions(b, features));
    return module;
}

/// `blackbox_options`, saying which optional modules were built: `blackbox.built_with`.
fn featureOptions(b: *std.Build, features: Features) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "jsonl", features.jsonl);
    options.addOption(bool, "chronicle", features.chronicle);
    return options.createModule();
}

/// blackbox's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    // A configuration's options (ci/workflow.json): the package is built with each optional module
    // or without, as a project would build it. The modules' own tests below build them either way.
    const features: Features = .{
        .jsonl = b.option(bool, "jsonl", "Build the package with blackbox_jsonl, as a configuration checks it") orelse false,
        .chronicle = b.option(bool, "chronicle", "Build the package with blackbox_chronicle, as a configuration checks it") orelse false,
    };
    const package = b.dependency("blackbox", .{ .target = target, .optimize = optimize, .jsonl = features.jsonl, .chronicle = features.chronicle });
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
                .{ .name = "blackbox_options", .module = featureOptions(b, features) },
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
    const jsonl = b.createModule(jsonlOptions(p, target, optimize, blackbox, strand));
    const chronicle_sink = b.createModule(chronicleOptions(p, target, optimize, blackbox, jsonl, chronicle));
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
    tools.preflight.addConsumerCheck(b, p, .{ .package = "blackbox", .program = p.path("ci/consumer.zig"), .packages = &.{ p.dependency("aegis", .{ .target = target, .optimize = optimize }), p.dependency("almanac", .{ .target = target, .optimize = optimize }), strand, chronicle } });
}

/// What each case of src/testing/secret_rejected.zig is refused with.
const secret_rejections = [_][]const u8{
    "the field fields.key holds one",
    "the field fields.bytes holds one",
    "the field fields.config.key holds one",
    "the field fields.message.args.0 holds one",
};
