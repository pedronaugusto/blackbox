//! blackbox: logging and tracing. Structured records with levels and typed fields, spans, a
//! `std.log` backend, and sinks; delivery at the call or through queues a drain task renders.
const std = @import("std");

pub const Level = @import("level.zig").Level;
pub const TraceId = @import("ids.zig").TraceId;
pub const SpanId = @import("ids.zig").SpanId;
pub const Logger = @import("Logger.zig");
pub const Scoped = @import("scoped.zig").Scoped;
pub const Producer = @import("Producer.zig");
pub const Span = @import("Span.zig");
pub const Site = @import("Site.zig");
pub const Sink = @import("Sink.zig");
pub const Record = @import("Record.zig");
pub const Field = @import("encode.zig").Field;
pub const Value = @import("encode.zig").Value;
pub const Text = @import("encode.zig").Text;
pub const TextSink = @import("sink/text.zig").TextSink;
pub const std_log = @import("std_log.zig");

/// What this build of blackbox has: `jsonl`, whether the package was built with `.jsonl = true`, and
/// so whether `@import("blackbox_jsonl")` is there.
pub const built_with: Features = .{ .jsonl = @import("blackbox_options").jsonl };
pub const Features = struct { jsonl: bool };

pub const lint_rules = .{
    .version = 2,
    .rules = .{
        .{ .id = .BB001, .name = "std.log's default", .kind = .ban, .reads = .replaces, .default = true, .purpose = "a program that imports blackbox routes std.log through its logger, so library records reach the same sinks and are counted" },
    },
    .replaces = .{
        .{ .rule = .BB001, .decl = std.log.defaultLog, .with = std_log.logFn, .why = "std.log's records reach blackbox's sinks and are counted", .door = .{std_log.logFn} },
    },
};

test {
    _ = @import("level.zig");
    _ = @import("options.zig");
    _ = @import("ids.zig");
    _ = @import("Site.zig");
    _ = @import("encode.zig");
    _ = @import("Record.zig");
    _ = @import("queue.zig");
    _ = @import("sink/text.zig");
    _ = Logger;
    _ = std_log;
}
