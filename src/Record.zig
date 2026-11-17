//! A record as a sink reads it, and the encoded form a queue holds: a fixed header (its length, its
//! site's address, the wall-clock time, the trace and span ids, the field count, the scope of a
//! span's record) and the encoded fields.
const Record = @This();
const std = @import("std");
const almanac = @import("almanac");
const Site = @import("Site.zig");
const Level = @import("level.zig").Level;
const ids = @import("ids.zig");
const encode = @import("encode.zig");

site: *const Site,
/// When the record was made, by the wall clock (`Io.Clock.real`).
at: almanac.Timestamp,
level: Level,
/// The scope: the site's, or for a record made through a span, the span's.
scope: []const u8,
trace: ?ids.TraceId,
span: ?ids.SpanId,
/// The encoded fields.
payload: []const u8,
count: u16,

/// The header's bytes: length (4), site (8), time (16), trace (16), span (8), field count (2), the
/// scope's length (2) and address (8).
pub const header_bytes = 64;

/// What a record says beyond its fields.
pub const Head = struct {
    site: *const Site,
    at: almanac.Timestamp,
    trace: ?ids.TraceId = null,
    span: ?ids.SpanId = null,
    /// A scope other than the site's: a span's, whose records' sites have none of their own.
    scope: ?[]const u8 = null,
};

/// Writes the header of a record of `len` bytes in all, holding `count` fields.
pub fn writeHeader(dest: *[header_bytes]u8, head: Head, len: usize, count: u16) void {
    std.mem.writeInt(u32, dest[0..4], @intCast(len), .little);
    std.mem.writeInt(u64, dest[4..12], @intFromPtr(head.site), .little);
    std.mem.writeInt(i128, dest[12..28], head.at.raw(), .little);
    std.mem.writeInt(u128, dest[28..44], if (head.trace) |t| t.raw() else 0, .little);
    std.mem.writeInt(u64, dest[44..52], if (head.span) |s| s.raw() else 0, .little);
    std.mem.writeInt(u16, dest[52..54], count, .little);
    const scope: []const u8 = head.scope orelse "";
    std.mem.writeInt(u16, dest[54..56], @intCast(scope.len), .little);
    std.mem.writeInt(u64, dest[56..64], if (head.scope != null) @intFromPtr(scope.ptr) else 0, .little);
}

/// The length a record's header gives: the record's bytes in all.
pub fn lengthOf(bytes: []const u8) usize {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// The time a record's header gives.
pub fn timeOf(bytes: []const u8) almanac.Timestamp {
    return .fromRaw(@intCast(std.mem.readInt(i128, bytes[12..28], .little)));
}

/// The record held in `bytes`, a header and its fields.
pub fn read(bytes: []const u8) Record {
    const len = lengthOf(bytes);
    const site: *const Site = @ptrFromInt(@as(usize, @intCast(std.mem.readInt(u64, bytes[4..12], .little))));
    const trace = std.mem.readInt(u128, bytes[28..44], .little);
    const span = std.mem.readInt(u64, bytes[44..52], .little);
    const scope_address = std.mem.readInt(u64, bytes[56..64], .little);
    const scope_len = std.mem.readInt(u16, bytes[54..56], .little);
    return .{
        .site = site,
        .at = timeOf(bytes),
        .level = site.level,
        .scope = if (scope_address == 0) site.scope else @as([*]const u8, @ptrFromInt(@as(usize, @intCast(scope_address))))[0..scope_len],
        .trace = ids.TraceId.fromRaw(trace) catch null,
        .span = ids.SpanId.fromRaw(span) catch null,
        .payload = bytes[header_bytes..len],
        .count = std.mem.readInt(u16, bytes[52..54], .little),
    };
}

/// The record's message: its site's, or for a `std.log` record the text formatted at the call.
pub fn message(record: *const Record) []const u8 {
    if (!record.site.formatted) return record.site.message;
    var it: encode.Iterator = .{ .bytes = record.payload, .left = record.count };
    const first = it.next() orelse return "";
    return switch (first.value) {
        .text => |t| t.bytes,
        else => "",
    };
}

/// The record's fields in the order they were given; a `std.log` record's message is not one.
pub fn fields(record: *const Record) encode.Iterator {
    var it: encode.Iterator = .{ .bytes = record.payload, .left = record.count };
    if (record.site.formatted) _ = it.next();
    return it;
}

test "a header round trips" {
    const site = Site.of(.warn, .db, "slow");
    var bytes: [header_bytes + 32]u8 = undefined;
    const fields_ = .{ .rows = 12 };
    const m = encode.measure(fields_);
    const put = encode.put(bytes[header_bytes..], fields_, &m, 64);
    writeHeader(bytes[0..header_bytes], .{ .site = site, .at = .fromRaw(5), .span = try ids.SpanId.fromRaw(7) }, header_bytes + put.used, put.count);
    const r = read(&bytes);
    try std.testing.expect(r.site == site);
    try std.testing.expectEqual(Level.warn, r.level);
    try std.testing.expectEqual(@as(?ids.TraceId, null), r.trace);
    try std.testing.expectEqual(@as(u64, 7), r.span.?.raw());
    try std.testing.expectEqualStrings("slow", r.message());
    var it = r.fields();
    try std.testing.expectEqual(@as(u64, 12), it.next().?.value.uint);
}
