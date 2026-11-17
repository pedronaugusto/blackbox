//! The field encoder: the fields of a call, an anonymous struct, as a compact binary form copied
//! into a record. Each field is its name (the address and length of the name the compiler made),
//! a kind and its value; strings and `format` output are copied in, since what they borrow may not
//! outlive the call. Encoding takes two passes over the values: `measure` finds each text's full
//! length, `put` writes them, cutting texts in order once a record's limit is reached, so a
//! record's size is known before it is written into a queue.
//!
//! A secret is refused at compile time: aegis's `Secret(T)`, `SecretBytes`, and any type holding
//! one, named by the field's path.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac");

/// A value's kind in the encoded form.
pub const Kind = enum(u8) { int, uint, float, bool, text, null };

/// Name address, name length, kind.
pub const name_bytes = 8 + 2 + 1;
/// A text's length and its cut mark, before its bytes.
pub const text_header = 4 + 1;

/// What a value is written as.
const Form = enum { int, uint, float, bool, string, formatted, tag, error_name, instant, wide, null, optional };

fn formOf(comptime T: type) Form {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .comptime_int => .wide,
        .int => |info| if (info.bits > 64) .wide else if (info.signedness == .signed) .int else .uint,
        .comptime_float, .float => .float,
        .null, .void => .null,
        .optional => .optional,
        .error_set => .error_name,
        .@"enum" => if (@hasDecl(T, "aegis_scalar")) aegisForm(T) else if (@hasDecl(T, "format")) .formatted else .tag,
        .@"struct", .@"union", .@"opaque" => if (@hasDecl(T, "format")) .formatted else @compileError(unsupported(T)),
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8) .string else @compileError(unsupported(T)),
            .one => switch (@typeInfo(info.child)) {
                .array => |array| if (array.child == u8) .string else @compileError(unsupported(T)),
                else => formOf(info.child),
            },
            else => @compileError(unsupported(T)),
        },
        .array => |info| if (info.child == u8) .string else @compileError(unsupported(T)),
        else => @compileError(unsupported(T)),
    };
}

fn unsupported(comptime T: type) []const u8 {
    return "blackbox: a field of type " ++ @typeName(T) ++ " is not a scalar, a string, an enum, an error, an optional of one, or a type with format";
}

fn aegisForm(comptime T: type) Form {
    return switch (T.aegis_scalar.kind) {
        .count, .id, .nonzero, .counter => if (@bitSizeOf(T.Representation) > 64) .wide else if (@typeInfo(T.Representation).int.signedness == .signed) .int else .uint,
        .instant => if (T.Clock == .real) .instant else if (@bitSizeOf(T.Representation) > 64) .wide else .int,
        else => if (@hasDecl(T, "format")) .formatted else .tag,
    };
}

/// A field's value as it is encoded: a number literal as a 64-bit integer of its sign or a float,
/// a pointer as what it points at.
inline fn normal(raw: anytype) Normal(@TypeOf(raw), if (@TypeOf(raw) == comptime_int) raw < 0 else false) {
    const T = @TypeOf(raw);
    if (T == comptime_int or T == comptime_float) return raw;
    return deref(raw);
}

fn Normal(comptime T: type, comptime negative: bool) type {
    if (T == comptime_int) return if (negative) i64 else u64;
    if (T == comptime_float) return f64;
    return Deref(T);
}

/// The value a pointer field points at, a pointer to an array of bytes kept as it is.
fn deref(value: anytype) Deref(@TypeOf(value)) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) != .array) deref(value.*) else value,
        else => value,
    };
}

fn Deref(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) != .array) Deref(info.child) else T,
        else => T,
    };
}

/// Refuses, at compile time, a type that is or holds an aegis secret.
pub fn refuseSecrets(comptime T: type, comptime path: []const u8) void {
    comptime refuseSecretsDepth(T, path, 0);
}

fn refuseSecretsDepth(comptime T: type, comptime path: []const u8, comptime depth: usize) void {
    if (depth > 6) return;
    if (T == aegis.SecretBytes or (@typeInfo(T) == .@"struct" and @hasField(T, "aegis_material")))
        @compileError("blackbox: a secret (" ++ @typeName(T) ++ ") reaches a log only through declassify, with its reason; the field " ++ path ++ " holds one");
    switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_names, info.field_types) |name, F| refuseSecretsDepth(F, path ++ "." ++ name, depth + 1),
        .@"union" => |info| for (info.field_names, info.field_types) |name, F| refuseSecretsDepth(F, path ++ "." ++ name, depth + 1),
        .optional => |info| refuseSecretsDepth(info.child, path, depth + 1),
        .pointer => |info| refuseSecretsDepth(info.child, path, depth + 1),
        .array => |info| refuseSecretsDepth(info.child, path, depth + 1),
        else => {},
    }
}

/// The full lengths of a call's texts, and the bytes of everything else.
pub fn Measure(comptime Fields: type) type {
    const count = @typeInfo(Fields).@"struct".field_names.len;
    return struct {
        /// Every byte that is not a text's own bytes.
        fixed: usize = 0,
        /// Each field's text length in full; zero for a field that is no text.
        texts: [count]usize = @splat(0),

        /// The bytes the fields take within `limit`: in full if they fit, else with their texts
        /// cut in order.
        pub fn size(m: *const @This(), limit: usize) usize {
            var total = m.fixed;
            var room = limit -| m.fixed;
            for (m.texts) |t| {
                const take = @min(t, room);
                total += take;
                room -= take;
            }
            return total;
        }
    };
}

/// The bytes each field of `fields` takes, its texts in full.
pub fn measure(fields: anytype) Measure(@TypeOf(fields)) {
    const Fields = @TypeOf(fields);
    comptime refuseSecrets(Fields, "fields");
    var m: Measure(Fields) = .{};
    inline for (@typeInfo(Fields).@"struct".field_names, 0..) |name, i| {
        const v = normal(@field(fields, name));
        m.fixed += name_bytes;
        switch (valueBytes(v)) {
            .fixed => |n| m.fixed += n,
            .text => |n| {
                m.fixed += text_header;
                m.texts[i] = n;
            },
        }
    }
    return m;
}

const Bytes = union(enum) { fixed: usize, text: usize };

fn valueBytes(v: anytype) Bytes {
    const T = @TypeOf(v);
    return switch (comptime formOf(T)) {
        .int, .uint, .float => .{ .fixed = 8 },
        .bool => .{ .fixed = 1 },
        .null => .{ .fixed = 0 },
        .optional => if (v) |inner| valueBytes(deref(inner)) else .{ .fixed = 0 },
        .string => .{ .text = string(v).len },
        .tag => .{ .text = tagName(v).len },
        .error_name => .{ .text = @errorName(v).len },
        .wide => .{ .text = counted("{d}", wideValue(v)) },
        .formatted => .{ .text = counted("{f}", v) },
        .instant => .{ .text = counted("{f}", Rfc3339(T){ .at = v }) },
    };
}

fn wideValue(v: anytype) WideOf(@TypeOf(v)) {
    const T = @TypeOf(v);
    return if (@typeInfo(T) == .@"enum") v.raw() else v;
}

fn WideOf(comptime T: type) type {
    return if (@typeInfo(T) == .@"enum") T.Representation else T;
}

fn counted(comptime format: []const u8, v: anytype) usize {
    var buffer: [64]u8 = undefined;
    var d: std.Io.Writer.Discarding = .init(&buffer);
    d.writer.print(format, .{v}) catch |err| switch (err) {
        error.WriteFailed => aegis.assert.never("blackbox: a discarding writer failed"),
    };
    return @intCast(d.fullCount());
}

fn string(v: anytype) []const u8 {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .array => &v,
        else => v,
    };
}

fn tagName(v: anytype) []const u8 {
    return std.enums.tagName(@TypeOf(v), v) orelse "(unnamed)";
}

/// An instant of the wall clock, written as RFC 3339 in UTC.
fn Rfc3339(comptime T: type) type {
    return struct {
        at: T,
        pub fn format(r: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            almanac.text.writeTimestamp(w, r.at, null) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
                else => try w.print("{d}", .{r.at.raw()}),
            };
        }
    };
}

/// What `put` wrote.
pub const Put = struct {
    /// Bytes written, at most the size `measure` gave for the same limit.
    used: usize,
    /// Fields written.
    count: u16,
    /// Whether a text was cut.
    cut: bool,
};

/// Writes `fields` into `dest`, which holds at least `m.size(limit)` bytes, cutting texts in order
/// past `limit`.
pub fn put(dest: []u8, fields: anytype, m: *const Measure(@TypeOf(fields)), limit: usize) Put {
    var at: usize = 0;
    var room = limit -| m.fixed;
    var cut = false;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names, 0..) |name, i| {
        const allot = @min(m.texts[i], room);
        room -= allot;
        const r = putField(dest[at..], name, normal(@field(fields, name)), allot);
        at += r.used;
        cut = cut or r.cut;
    }
    return .{ .used = at, .count = @typeInfo(@TypeOf(fields)).@"struct".field_names.len, .cut = cut };
}

const Written = struct { used: usize, cut: bool };

/// One field: its name, then its value, a text in at most `allot` bytes.
pub fn putField(dest: []u8, comptime name: []const u8, v: anytype, allot: usize) Written {
    std.mem.writeInt(u64, dest[0..8], @intFromPtr(name.ptr), .little);
    std.mem.writeInt(u16, dest[8..10], @intCast(name.len), .little);
    const r = putValue(dest[name_bytes - 1 ..], v, allot);
    return .{ .used = name_bytes - 1 + r.used, .cut = r.cut };
}

fn putValue(dest: []u8, v: anytype, allot: usize) Written {
    const T = @TypeOf(v);
    switch (comptime formOf(T)) {
        .int => return number(dest, .int, @as(i64, if (@typeInfo(T) == .@"enum") v.raw() else v)),
        .uint => return number(dest, .uint, @as(u64, if (@typeInfo(T) == .@"enum") v.raw() else v)),
        .float => {
            dest[0] = @backingInt(Kind.float);
            std.mem.writeInt(u64, dest[1..9], @bitCast(@as(f64, @floatCast(v))), .little);
            return .{ .used = 9, .cut = false };
        },
        .bool => {
            dest[0] = @backingInt(Kind.bool);
            dest[1] = @intFromBool(v);
            return .{ .used = 2, .cut = false };
        },
        .null => {
            dest[0] = @backingInt(Kind.null);
            return .{ .used = 1, .cut = false };
        },
        .optional => {
            if (v) |inner| return putValue(dest, deref(inner), allot);
            dest[0] = @backingInt(Kind.null);
            return .{ .used = 1, .cut = false };
        },
        .string => return text(dest, string(v), allot),
        .tag => return text(dest, tagName(v), allot),
        .error_name => return text(dest, @errorName(v), allot),
        .wide => return printed(dest, "{d}", wideValue(v), allot),
        .formatted => return printed(dest, "{f}", v, allot),
        .instant => return printed(dest, "{f}", Rfc3339(T){ .at = v }, allot),
    }
}

fn number(dest: []u8, kind: Kind, v: anytype) Written {
    dest[0] = @backingInt(kind);
    std.mem.writeInt(@TypeOf(v), dest[1..9], v, .little);
    return .{ .used = 9, .cut = false };
}

/// A text's bytes, cut to `allot` at a character's start.
pub fn text(dest: []u8, bytes: []const u8, allot: usize) Written {
    const len = if (bytes.len <= allot) bytes.len else whole(bytes[0..allot]);
    dest[0] = @backingInt(Kind.text);
    std.mem.writeInt(u32, dest[1..5], @intCast(len), .little);
    dest[5] = @intFromBool(len < bytes.len);
    @memcpy(dest[text_header + 1 ..][0..len], bytes[0..len]);
    return .{ .used = 1 + text_header + len, .cut = len < bytes.len };
}

/// The length of `prefix` without a UTF-8 sequence its cut left incomplete at its end.
fn whole(prefix: []const u8) usize {
    var n = prefix.len;
    var back: usize = 0;
    while (n > 0 and back < 4) : (back += 1) {
        const b = prefix[n - 1];
        if (b & 0xc0 != 0x80) {
            // A lead byte: the sequence it starts, if a multi-byte one, must be whole.
            const want: usize = if (b < 0x80) 1 else if (b & 0xe0 == 0xc0) 2 else if (b & 0xf0 == 0xe0) 3 else if (b & 0xf8 == 0xf0) 4 else 1;
            return if (back + 1 >= want) prefix.len else n - 1;
        }
        n -= 1;
    }
    return prefix.len;
}

fn printed(dest: []u8, comptime format: []const u8, v: anytype, allot: usize) Written {
    dest[0] = @backingInt(Kind.text);
    var w: std.Io.Writer = .fixed(dest[1 + text_header ..][0..allot]);
    var cut = false;
    w.print(format, .{v}) catch {
        cut = true;
    };
    var len = w.end;
    if (cut) len = whole(dest[1 + text_header ..][0..len]);
    std.mem.writeInt(u32, dest[1..5], @intCast(len), .little);
    dest[5] = @intFromBool(cut);
    return .{ .used = 1 + text_header + len, .cut = cut };
}

/// A field as a sink reads it.
pub const Field = struct { name: []const u8, value: Value };

/// A field's value.
pub const Value = union(Kind) {
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    text: Text,
    null,
};

/// A text value; `cut` when the record's limit cut it.
pub const Text = struct { bytes: []const u8, cut: bool };

/// The fields of an encoded payload, in order.
pub const Iterator = struct {
    bytes: []const u8,
    left: u16,

    pub fn next(it: *Iterator) ?Field {
        if (it.left == 0) return null;
        it.left -= 1;
        const b = it.bytes;
        const address: usize = @intCast(std.mem.readInt(u64, b[0..8], .little));
        const len = std.mem.readInt(u16, b[8..10], .little);
        const name = @as([*]const u8, @ptrFromInt(address))[0..len];
        const kind: Kind = @fromBackingInt(@intCast(b[10]));
        const v = b[11..];
        var used: usize = 8;
        const value: Value = switch (kind) {
            .int => .{ .int = std.mem.readInt(i64, v[0..8], .little) },
            .uint => .{ .uint = std.mem.readInt(u64, v[0..8], .little) },
            .float => .{ .float = @bitCast(std.mem.readInt(u64, v[0..8], .little)) },
            .bool => blk: {
                used = 1;
                break :blk .{ .bool = v[0] != 0 };
            },
            .null => blk: {
                used = 0;
                break :blk .null;
            },
            .text => blk: {
                const n = std.mem.readInt(u32, v[0..4], .little);
                used = text_header + n;
                break :blk .{ .text = .{ .bytes = v[text_header..][0..n], .cut = v[4] != 0 } };
            },
        };
        it.bytes = b[name_bytes + used ..];
        return .{ .name = name, .value = value };
    }
};

const testing = std.testing;

fn roundTrip(fields: anytype, limit: usize, buffer: []u8) Iterator {
    const m = measure(fields);
    const size = m.size(limit);
    const r = put(buffer[0..size], fields, &m, limit);
    aegis.assert.invariant(r.used <= size, "put writes no more than measure gave");
    return .{ .bytes = buffer[0..r.used], .left = r.count };
}

test "every kind round trips" {
    const Colour = enum { red, green };
    const Took = aegis.units.Duration(.nanosecond, i64);
    var buffer: [1024]u8 = undefined;
    const name: []const u8 = "/index.html";
    const missing: ?u32 = null;
    var it = roundTrip(.{
        .status = 200,
        .delta = @as(i32, -7),
        .ratio = @as(f32, 0.5),
        .ok = true,
        .path = name,
        .literal = "lit",
        .colour = Colour.green,
        .failure = error.Refused,
        .missing = missing,
        .present = @as(?u8, 9),
        .took = Took.fromRaw(1_200_000),
        .wide = @as(u128, 1) << 100,
        .negative = -5,
    }, 1024, &buffer);
    try testing.expectEqual(@as(u64, 200), it.next().?.value.uint);
    try testing.expectEqual(@as(i64, -7), it.next().?.value.int);
    try testing.expectEqual(@as(f64, 0.5), it.next().?.value.float);
    try testing.expectEqual(true, it.next().?.value.bool);
    const path = it.next().?;
    try testing.expectEqualStrings("path", path.name);
    try testing.expectEqualStrings("/index.html", path.value.text.bytes);
    try testing.expectEqualStrings("lit", it.next().?.value.text.bytes);
    try testing.expectEqualStrings("green", it.next().?.value.text.bytes);
    try testing.expectEqualStrings("Refused", it.next().?.value.text.bytes);
    try testing.expectEqual(Value.null, it.next().?.value);
    try testing.expectEqual(@as(u64, 9), it.next().?.value.uint);
    try testing.expectEqualStrings("1ms200us", it.next().?.value.text.bytes);
    try testing.expectEqualStrings("1267650600228229401496703205376", it.next().?.value.text.bytes);
    try testing.expectEqual(@as(i64, -5), it.next().?.value.int);
    try testing.expectEqual(@as(?Field, null), it.next());
}

test "texts past the limit are cut in order, at a character's start, and marked" {
    var buffer: [256]u8 = undefined;
    const fields = .{ .a = "0123456789", .b = "caf\u{e9}s", .c = "zz" };
    const m = measure(fields);
    // Room for the fixed bytes and 13 text bytes: a whole, then b cut inside its é.
    var it = roundTrip(fields, m.fixed + 14, &buffer);
    const a = it.next().?.value.text;
    try testing.expectEqualStrings("0123456789", a.bytes);
    try testing.expect(!a.cut);
    const b = it.next().?.value.text;
    try testing.expectEqualStrings("caf", b.bytes);
    try testing.expect(b.cut);
    const c = it.next().?.value.text;
    try testing.expectEqualStrings("", c.bytes);
    try testing.expect(c.cut);
}

test "a formatted value past the limit is cut and marked" {
    const Took = aegis.units.Duration(.nanosecond, i64);
    var buffer: [256]u8 = undefined;
    const fields = .{ .took = Took.fromRaw(1_200_000) };
    const m = measure(fields);
    var it = roundTrip(fields, m.fixed + 3, &buffer);
    const took = it.next().?.value.text;
    try testing.expectEqualStrings("1ms", took.bytes);
    try testing.expect(took.cut);
}

test "an instant of the wall clock is written as RFC 3339" {
    var buffer: [256]u8 = undefined;
    const at = almanac.Timestamp.fromRaw(1_700_000_000_123_000_000);
    var it = roundTrip(.{ .at = at }, 256, &buffer);
    try testing.expectEqualStrings("2023-11-14T22:13:20.123Z", it.next().?.value.text.bytes);
}
