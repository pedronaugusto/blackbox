//! Levels: `std.log`'s four and `trace` below them.
const std = @import("std");

/// How much a record matters, lowest first.
pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,

    /// Whether a record at `level` passes `floor`.
    pub fn passes(level: Level, floor: Level) bool {
        return @backingInt(level) >= @backingInt(floor);
    }

    /// `std.log`'s level as blackbox's.
    pub fn fromStd(comptime level: std.log.Level) Level {
        return switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }

    /// The level as a text sink writes it: upper case, five columns wide.
    pub fn label(level: Level) []const u8 {
        return switch (level) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }

    /// The level as a JSON sink names it.
    pub fn name(level: Level) []const u8 {
        return @tagName(level);
    }
};

test "levels order trace below err" {
    try std.testing.expect(Level.err.passes(.warn));
    try std.testing.expect(!Level.trace.passes(.debug));
    try std.testing.expect(Level.info.passes(.info));
    try std.testing.expectEqual(Level.err, Level.fromStd(.err));
}
