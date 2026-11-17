//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/level.zig", "src/ids.zig", "src/options.zig" } },
    .{ .name = "record", .patterns = &.{ "src/Site.zig", "src/encode.zig", "src/Record.zig", "src/queue.zig" } },
    .{ .name = "sink", .patterns = &.{ "src/Sink.zig", "src/sink/text.zig" } },
    .{ .name = "core", .patterns = &.{"src/Core.zig"} },
    .{ .name = "trace", .patterns = &.{"src/Span.zig"} },
    .{ .name = "calls", .patterns = &.{ "src/scoped.zig", "src/Producer.zig" } },
    .{ .name = "logger", .patterns = &.{ "src/Logger.zig", "src/std_log.zig" } },
    .{ .name = "root", .patterns = &.{"src/blackbox.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "blackbox", .path = "src/blackbox.zig" },
};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "almanac", "shakedown", "builtin", "blackbox", "rejection_options" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/level.zig",
    "src/ids.zig",
    "src/options.zig",
    "src/Site.zig",
    "src/encode.zig",
    "src/Record.zig",
    "src/queue.zig",
    "src/Sink.zig",
    "src/sink/text.zig",
    "src/Core.zig",
    "src/scoped.zig",
    "src/Logger.zig",
    "src/Producer.zig",
    "src/Span.zig",
    "src/std_log.zig",
    "src/blackbox.zig",
};
