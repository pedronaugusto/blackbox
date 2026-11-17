//! The `std.log` backend: every library that logs through `std.log` reaches the logger's sinks.
//! std's `logFn` has no context, so the logger is reached through one atomic pointer the program
//! sets: `install` before the first record, `uninstall` before the logger's `deinit`. Before
//! `install` and after `uninstall` a record goes to stderr through `std.log.defaultLog` and is
//! counted, and the logger's `status` reports the count. `std.log` has no `Io` of its own: records
//! are made with `std.Options.debug_io`, as `std.log.defaultLog` does.
const std = @import("std");
const aegis = @import("aegis");
const Logger = @import("Logger.zig");
const Core = @import("Core.zig");
const Site = @import("Site.zig");
const Level = @import("level.zig").Level;

var installed: aegis.Atomic(?*Logger) = .init(null);

/// Routes `std.log` to `logger`.
pub fn install(logger: *Logger) void {
    installed.store(logger, .release);
}

/// Routes `std.log` back to stderr.
pub fn uninstall() void {
    installed.store(null, .release);
}

/// `std_options.logFn`.
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime text: []const u8, args: anytype) void {
    const logger = installed.load(.acquire) orelse {
        _ = Core.before_install.fetchAddWrapping(.fromRaw(1), .monotonic);
        std.log.defaultLog(level, scope, text, args);
        return;
    };
    const site = comptime Site.formattedOf(Level.fromStd(level), scope, text);
    Core.emit(.{ .core = &logger.core }, std.Options.debug_io, site, .{}, .{ .message = Formatted(text, @TypeOf(args)){ .args = args } });
}

/// A `std.log` call's message, formatted when the record is encoded.
fn Formatted(comptime text: []const u8, comptime Args: type) type {
    return struct {
        args: Args,
        pub fn format(f: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print(text, f.args);
        }
    };
}
