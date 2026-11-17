//! The compile-time floors: a record below its scope's floor is not compiled. They are std's own,
//! `std_options.log_level` and `std_options.log_scope_levels`, which `std.log` reads, so one setting
//! serves both. std has no trace level: a floor of `debug`, std's lowest, admits blackbox's trace.
const std = @import("std");
const Level = @import("level.zig").Level;

/// The floor every scope not named in `log_scope_levels` has.
pub const default_floor: Level = fromStd(std.options.log_level);

/// The floor of `scope`.
pub fn floor(comptime scope: @EnumLiteral()) Level {
    inline for (std.options.log_scope_levels) |s| {
        if (s.scope == scope) return fromStd(s.level);
    }
    return default_floor;
}

fn fromStd(comptime level: std.log.Level) Level {
    return if (level == .debug) .trace else Level.fromStd(level);
}

test "std's debug floor admits trace" {
    try std.testing.expectEqual(Level.trace, fromStd(.debug));
    try std.testing.expectEqual(Level.warn, fromStd(.warn));
}
