//! Trace and span ids, in W3C Trace Context's shapes: a 128-bit trace id and a 64-bit span id,
//! neither zero, drawn from the `Io`'s random source.
const std = @import("std");
const aegis = @import("aegis");

/// Tags that keep the two id domains apart.
pub const TraceTag = struct {};
pub const SpanTag = struct {};

/// A trace: every span of one operation shares it.
pub const TraceId = aegis.id.NonZero(TraceTag, u128);
/// A span within its trace.
pub const SpanId = aegis.id.NonZero(SpanTag, u64);

/// A new trace id from `io`'s random source; zero, which Trace Context reserves, is drawn again.
pub fn newTrace(io: std.Io) TraceId {
    while (true) {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        const raw = std.mem.readInt(u128, &bytes, .big);
        if (raw != 0) return TraceId.fromRaw(raw) catch aegis.assert.never("blackbox: a nonzero id is refused");
    }
}

/// A new span id from `io`'s random source; zero is drawn again.
pub fn newSpan(io: std.Io) SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        const raw = std.mem.readInt(u64, &bytes, .big);
        if (raw != 0) return SpanId.fromRaw(raw) catch aegis.assert.never("blackbox: a nonzero id is refused");
    }
}

/// An id as Trace Context writes it: lower-case hex, zero-padded to its width.
pub fn writeHex(w: *std.Io.Writer, id: anytype) std.Io.Writer.Error!void {
    const Repr = @TypeOf(id.raw());
    const digits = @bitSizeOf(Repr) / 4;
    try w.print("{x:0>[1]}", .{ id.raw(), digits });
}

test "ids are never zero and print at their width" {
    const io = std.testing.io;
    for (0..32) |_| {
        try std.testing.expect(newTrace(io).raw() != 0);
        try std.testing.expect(newSpan(io).raw() != 0);
    }
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeHex(&w, try SpanId.fromRaw(0xab));
    try std.testing.expectEqualStrings("00000000000000ab", w.buffered());
}
