//! The text sink: a record as one line in logfmt's shape, after its time, level, scope and message:
//!
//!   2026-11-17T16:32:02.123Z INFO  http: answered status=200 took=1ms200us trace=4bf9… span=00f0…
//!
//! A value is written bare where it can be read back bare, else quoted with `\"`, `\\` and control
//! bytes as `\x..`; a message's control bytes are escaped the same way, so a field cannot forge a
//! line. A text the record's limit cut is quoted and followed by `…`. Colour is the caller's
//! terminal mode; blackbox reads no environment.
const std = @import("std");
const almanac = @import("almanac");
const Sink = @import("../Sink.zig");
const Record = @import("../Record.zig");
const encode = @import("../encode.zig");
const ids = @import("../ids.zig");
const Terminal = std.Io.Terminal;

pub const TextSink = struct {
    sink: Sink = .{ .vtable = &vtable },
    writer: *std.Io.Writer,
    options: Options,

    pub const Options = struct {
        /// `std.Io.Terminal.Mode.detect(io, file, NO_COLOR, CLICOLOR_FORCE)` with the environment the
        /// program read.
        color: Terminal.Mode = .no_color,
        /// The zone times are written in; UTC when null.
        zone: ?*const almanac.TimeZone = null,
    };

    const vtable: Sink.VTable = .{ .write = write, .flush = flush };

    pub fn init(writer: *std.Io.Writer, options: Options) TextSink {
        return .{ .writer = writer, .options = options };
    }

    fn write(sink: *Sink, io: std.Io, record: *const Record) Sink.WriteError!void {
        _ = io;
        const self: *TextSink = @fieldParentPtr("sink", sink);
        try render(self.writer, record, self.options);
        try self.writer.flush();
    }

    fn flush(sink: *Sink, io: std.Io) Sink.WriteError!void {
        _ = io;
        const self: *TextSink = @fieldParentPtr("sink", sink);
        try self.writer.flush();
    }
};

/// One record as one line, its newline included.
pub fn render(w: *std.Io.Writer, record: *const Record, options: TextSink.Options) std.Io.Writer.Error!void {
    const t: Terminal = .{ .writer = w, .mode = options.color };
    const offset: ?almanac.Offset = if (options.zone) |zone| zone.offsetAt(record.at) catch null else null;
    try color(t, .dim);
    almanac.text.writeTimestamp(w, record.at, offset) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => try w.print("{d}", .{record.at.raw()}),
    };
    try color(t, .reset);
    try w.writeByte(' ');
    try color(t, switch (record.level) {
        .trace => .bright_black,
        .debug => .blue,
        .info => .green,
        .warn => .yellow,
        .err => .red,
    });
    try w.writeAll(record.level.label());
    try color(t, .reset);
    try w.writeByte(' ');
    try w.writeAll(record.scope);
    try w.writeAll(": ");
    try escaped(w, record.message());
    var it = record.fields();
    while (it.next()) |field| {
        try w.writeByte(' ');
        try color(t, .dim);
        try key(w, field.name);
        try w.writeByte('=');
        try color(t, .reset);
        try value(w, field.value);
    }
    if (record.trace) |trace| {
        try w.writeAll(" trace=");
        try ids.writeHex(w, trace);
    }
    if (record.span) |span| {
        try w.writeAll(" span=");
        try ids.writeHex(w, span);
    }
    try w.writeByte('\n');
}

/// A colour, or with no colour mode nothing; a colour that cannot be set fails the write.
fn color(t: Terminal, c: Terminal.Color) std.Io.Writer.Error!void {
    t.setColor(c) catch |err| switch (err) {
        error.WriteFailed, error.Canceled, error.Unexpected => return error.WriteFailed,
    };
}

fn key(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |b| try w.writeByte(if (bare(b)) b else '_');
}

/// A value: numbers and booleans as they are, `null`, a text bare where it can be.
pub fn value(w: *std.Io.Writer, v: encode.Value) std.Io.Writer.Error!void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .uint => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .text => |text| {
            if (!text.cut and text.bytes.len > 0 and for (text.bytes) |b| {
                if (!bare(b)) break false;
            } else true) return w.writeAll(text.bytes);
            try w.writeByte('"');
            for (text.bytes) |b| switch (b) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                else => if (b < 0x20 or b == 0x7f) try w.print("\\x{x:0>2}", .{b}) else try w.writeByte(b),
            };
            try w.writeByte('"');
            if (text.cut) try w.writeAll("…");
        },
    }
}

/// Whether a byte may stand in a bare value: printable, and not a space, `=` or `"`.
fn bare(b: u8) bool {
    return b > 0x20 and b != 0x7f and b != '=' and b != '"' and b != '\\';
}

/// A message, its control bytes as `\x..` and backslashes doubled.
fn escaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |b| {
        if (b < 0x20 or b == 0x7f) try w.print("\\x{x:0>2}", .{b}) else if (b == '\\') try w.writeAll("\\\\") else try w.writeByte(b);
    }
}

const testing = std.testing;
const Site = @import("../Site.zig");

fn line(fields: anytype, head: Record.Head, options: TextSink.Options) ![]u8 {
    var bytes: [Record.header_bytes + 512]u8 = undefined;
    const m = encode.measure(fields);
    const p = encode.put(bytes[Record.header_bytes..], fields, &m, 512);
    Record.writeHeader(bytes[0..Record.header_bytes], head, Record.header_bytes + p.used, p.count);
    const r = Record.read(&bytes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer, &r, options);
    return out.toOwnedSlice();
}

test "a record as one logfmt line" {
    const at = almanac.Timestamp.fromRaw(1_700_000_000_123_000_000);
    const text = try line(.{ .status = 200, .path = "/a b", .ok = true, .nothing = null }, .{ .site = Site.of(.info, .http, "answered"), .at = at, .span = try ids.SpanId.fromRaw(255) }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("2023-11-14T22:13:20.123Z INFO  http: answered status=200 path=\"/a b\" ok=true nothing=null span=00000000000000ff\n", text);
}

test "a field cannot forge a line" {
    const at = almanac.Timestamp.fromRaw(0);
    const site = Site.of(.warn, .default, "bad\ninput");
    const text = try line(.{ .value = "x\n1970-01-01T00:00:00Z ERROR forged=\"yes\"" }, .{ .site = site, .at = at }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    try testing.expectEqualStrings("1970-01-01T00:00:00Z WARN  default: bad\\x0ainput value=\"x\\x0a1970-01-01T00:00:00Z ERROR forged=\\\"yes\\\"\"\n", text);
}

test "colour comes from the caller's mode" {
    const site = Site.of(.err, .db, "down");
    const text = try line(.{}, .{ .site = site, .at = .fromRaw(0) }, .{ .color = .escape_codes });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "\x1b[31mERROR\x1b[0m") != null);
}
