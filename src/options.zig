//! The compile-time floors: a record below its scope's floor is not compiled. A program sets them
//! as it sets `std_options`:
//!
//!   pub const blackbox_options: blackbox.Options = .{ .level = .info, .scopes = &.{.{ .scope = .db, .level = .debug }} };
const builtin = @import("builtin");
const root = @import("root");
const Level = @import("level.zig").Level;

/// One scope's floor.
pub const ScopeLevel = struct { scope: @EnumLiteral(), level: Level };

pub const Options = struct {
    /// Every scope's floor but those named: `std.log`'s default, debug in Debug builds, else info.
    level: Level = if (builtin.mode == .Debug) .debug else .info,
    scopes: []const ScopeLevel = &.{},
};

/// The program's options, or the defaults.
pub const options: Options = if (@hasDecl(root, "blackbox_options")) root.blackbox_options else .{};

/// The floor of `scope`.
pub fn floor(comptime scope: @EnumLiteral()) Level {
    inline for (options.scopes) |s| {
        if (s.scope == scope) return s.level;
    }
    return options.level;
}
