//! The calls of one scope, on a logger or a producer.
const std = @import("std");
const Io = std.Io;
const Core = @import("Core.zig");
const Level = @import("level.zig").Level;
const Site = @import("Site.zig");
const Span = @import("Span.zig");
const options = @import("options.zig");

pub fn Scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        target: Core.Target,

        const floor = options.floor(scope);

        pub fn trace(s: @This(), io: Io, comptime message: []const u8, fields: anytype) void {
            s.log(io, .trace, message, fields);
        }
        pub fn debug(s: @This(), io: Io, comptime message: []const u8, fields: anytype) void {
            s.log(io, .debug, message, fields);
        }
        pub fn info(s: @This(), io: Io, comptime message: []const u8, fields: anytype) void {
            s.log(io, .info, message, fields);
        }
        pub fn warn(s: @This(), io: Io, comptime message: []const u8, fields: anytype) void {
            s.log(io, .warn, message, fields);
        }
        pub fn err(s: @This(), io: Io, comptime message: []const u8, fields: anytype) void {
            s.log(io, .err, message, fields);
        }

        /// A record at `level`, unless the scope's compile-time floor is above it.
        pub fn log(s: @This(), io: Io, comptime level: Level, comptime message: []const u8, fields: anytype) void {
            if (comptime !level.passes(floor)) return;
            Core.emit(s.target, io, Site.of(level, scope, message), .{}, fields);
        }

        /// A span: written with its duration when it ends. Below the scope's floor it still carries
        /// ids, and writes nothing.
        pub fn span(s: @This(), io: Io, comptime level: Level, comptime name: []const u8, fields: anytype) Span {
            const site: ?*const Site = comptime if (level.passes(floor)) Site.of(level, scope, name) else null;
            return Span.begin(s.target, io, level, @tagName(scope), site, null, null, fields);
        }
    };
}
