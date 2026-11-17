//! A callsite: its level, scope and message, made once per site at compile time. A record carries
//! the site's address, so nothing about the site is copied or formatted at the call.
const Site = @This();
const Level = @import("level.zig").Level;

level: Level,
/// The scope's name, as `std.log.scoped` names it (`default` when none).
scope: []const u8,
/// The message as written at the site; for a record from `std.log`, its format string.
message: []const u8,
/// Whether the record's first field is its message, formatted at the call (a `std.log` record's).
formatted: bool = false,

/// The one site of a level, scope and message: the same three give the same address.
pub fn of(comptime level: Level, comptime scope: @EnumLiteral(), comptime message: []const u8) *const Site {
    return &struct {
        const site: Site = .{ .level = level, .scope = @tagName(scope), .message = message };
    }.site;
}

/// A site whose message is formatted at the call, for `std.log`'s records.
pub fn formattedOf(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8) *const Site {
    return &struct {
        const site: Site = .{ .level = level, .scope = @tagName(scope), .message = format, .formatted = true };
    }.site;
}

test "one site per level, scope and message" {
    const std = @import("std");
    try std.testing.expect(of(.info, .http, "answered") == of(.info, .http, "answered"));
    try std.testing.expect(of(.info, .http, "answered") != of(.warn, .http, "answered"));
    try std.testing.expectEqualStrings("http", of(.info, .http, "answered").scope);
}
