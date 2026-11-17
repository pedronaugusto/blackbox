//! The field encoder and the text renderer on arbitrary values: every kind round trips, a text cut at
//! any limit is a prefix of the whole, marked, and never ends inside a character it was given
//! whole; and whatever bytes a field holds, the text sink writes one line.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const encode = @import("../encode.zig");
const Record = @import("../Record.zig");
const Site = @import("../Site.zig");
const text_sink = @import("../sink/text.zig");

const Colour = enum { red, green, blue };

fn roundTrip(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const bytes = try gpa.alloc(u8, gen.intRange(s, usize, 0, 300));
    _ = gen.bytesInto(s, bytes);
    const words = try gen.string(s, gpa, .{});
    const fields = .{
        .a = gen.int(s, i64),
        .b = gen.int(s, u32),
        .c = gen.float(s, f64),
        .d = gen.boolean(s),
        .e = @as([]const u8, bytes),
        .f = if (gen.boolean(s)) @as(?i16, gen.int(s, i16)) else null,
        .g = gen.enumValue(s, Colour),
        .h = gen.int(s, u128),
        .i = @as([]const u8, words),
    };
    const m = encode.measure(fields);
    const whole = m.size(std.math.maxInt(usize));
    const limit = gen.intRange(s, usize, m.fixed, whole + 8);
    const size = m.size(limit);
    try testing.expect(size <= @max(limit, m.fixed));
    const buffer = try gpa.alloc(u8, size);
    const p = encode.put(buffer, fields, &m, limit);
    try testing.expect(p.used <= size);
    try testing.expectEqual(limit < whole, p.cut);
    var it: encode.Iterator = .{ .bytes = buffer[0..p.used], .left = p.count };
    try testing.expectEqual(fields.a, it.next().?.value.int);
    try testing.expectEqual(@as(u64, fields.b), it.next().?.value.uint);
    try testing.expectEqual(@as(u64, @bitCast(fields.c)), @as(u64, @bitCast(it.next().?.value.float)));
    try testing.expectEqual(fields.d, it.next().?.value.bool);
    try expectPrefix(fields.e, it.next().?.value.text);
    const f = it.next().?.value;
    if (fields.f) |v| try testing.expectEqual(@as(i64, v), f.int) else try testing.expectEqual(encode.Value.null, f);
    try expectPrefix(@tagName(fields.g), it.next().?.value.text);
    var digits: [40]u8 = undefined;
    var w: std.Io.Writer = .fixed(&digits);
    try w.print("{d}", .{fields.h});
    try expectPrefix(w.buffered(), it.next().?.value.text);
    try expectPrefix(fields.i, it.next().?.value.text);
    try testing.expectEqual(@as(?encode.Field, null), it.next());
}

/// A text as encoded: the whole of `given`, or a prefix marked as cut; a prefix of valid UTF-8 is
/// valid UTF-8.
fn expectPrefix(given: []const u8, got: encode.Text) !void {
    try testing.expect(std.mem.startsWith(u8, given, got.bytes));
    try testing.expectEqual(got.bytes.len < given.len, got.cut);
    if (std.unicode.utf8ValidateSlice(given)) try testing.expect(std.unicode.utf8ValidateSlice(got.bytes));
}

test "encoder: every kind round trips, and texts are cut to prefixes at any limit" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .cases = 500, .seed = 0xb1ac });
}

fn oneLine(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const value = try gpa.alloc(u8, gen.intRange(s, usize, 0, 200));
    _ = gen.bytesInto(s, value);
    const fields = .{ .value = @as([]const u8, value), .n = gen.int(s, i32) };
    var bytes: [Record.header_bytes + 512]u8 = undefined;
    const m = encode.measure(fields);
    const limit = gen.intRange(s, usize, m.fixed, 512);
    const p = encode.put(bytes[Record.header_bytes..], fields, &m, limit);
    const site = Site.of(.info, .fuzz, "value");
    Record.writeHeader(bytes[0..Record.header_bytes], .{ .site = site, .at = .fromRaw(gen.int(s, i64)) }, Record.header_bytes + p.used, p.count);
    const record = Record.read(&bytes);
    var out: std.Io.Writer.Allocating = .init(gpa);
    try text_sink.render(&out.writer, &record, .{});
    const line = out.written();
    try testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    for (line[0 .. line.len - 1]) |b| try testing.expect(b >= 0x20 and b != 0x7f);
}

test "text sink: whatever bytes a field holds, one line" {
    try shakedown.check(testing.allocator, {}, oneLine, .{ .cases = 500, .seed = 0x11e });
}
