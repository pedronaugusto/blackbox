//! The JSON Lines sink: its records in slog's shape, read back by strand whatever bytes their fields
//! hold, and its file opened again by its path after a rotation.
const std = @import("std");
const testing = std.testing;
const blackbox = @import("blackbox");
const JsonlSink = @import("blackbox_jsonl").JsonlSink;
const strand = @import("strand");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

/// A line from `"level"` on: what does not change from run to run.
fn afterTime(line: []const u8) []const u8 {
    const start = std.mem.find(u8, line, "\",\"level\"").?;
    return line[start + 2 ..];
}

test "jsonl: a record as one JSON line in slog's shape" {
    const io = testing.io;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var sink: JsonlSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.http).info(io, "answered", .{ .status = 200, .path = "/a \"b\"\n", .ok = true, .nothing = null, .ratio = 0.5, .neg = -3 });
    const line = out.written();
    try testing.expect(std.mem.startsWith(u8, line, "{\"time\":\""));
    try testing.expectEqualStrings("\"level\":\"INFO\",\"scope\":\"http\",\"msg\":\"answered\",\"status\":200,\"path\":\"/a \\\"b\\\"\\n\",\"ok\":true,\"nothing\":null,\"ratio\":0.5,\"neg\":-3}\n", afterTime(line));
    // The time is RFC 3339's, as the text sink writes it.
    const parsed = try strand.json.parseStdValue(testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    const time = parsed.value.object.get("time").?.string;
    try testing.expect(time.len >= 20 and time[10] == 'T' and time[time.len - 1] == 'Z');
}

test "jsonl: ids in hex at their full width, a span's scope, and a message's bytes escaped" {
    var bytes: [blackbox.Record.header_bytes]u8 = undefined;
    const site = blackbox.Site.of(.warn, .db, "slow\x01\"");
    blackbox.Record.writeHeader(&bytes, .{
        .site = site,
        .at = @import("almanac").Timestamp.fromRaw(1_700_000_000_123_000_000),
        .trace = try blackbox.TraceId.fromRaw(0xabc),
        .span = try blackbox.SpanId.fromRaw(0xff),
        .scope = "pool",
    }, blackbox.Record.header_bytes, 0);
    const record = blackbox.Record.read(&bytes);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try @import("blackbox_jsonl").render(&out.writer, &record, .{});
    try testing.expectEqualStrings("{\"time\":\"2023-11-14T22:13:20.123Z\",\"level\":\"WARN\",\"scope\":\"pool\",\"msg\":\"slow\\u0001\\\"\",\"trace\":\"00000000000000000000000000000abc\",\"span\":\"00000000000000ff\"}\n", out.written());
}

test "jsonl: spans' ids in hex, and floats JSON has no number for as strings" {
    const io = testing.io;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var sink: JsonlSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{ .level = .trace });
    defer logger.deinit(io);
    const log = logger.scoped(.db);
    var span = log.span(io, .debug, "query", .{});
    span.trace(io, "odd", .{ .nan = std.math.nan(f64), .up = std.math.inf(f64), .down = -std.math.inf(f64) });
    span.end(io);
    const parsed = try strand.json.parseStdValue(testing.allocator, std.mem.sliceTo(out.written(), '\n'), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("TRACE", o.get("level").?.string);
    try testing.expectEqualStrings("NaN", o.get("nan").?.string);
    try testing.expectEqualStrings("Infinity", o.get("up").?.string);
    try testing.expectEqualStrings("-Infinity", o.get("down").?.string);
    try testing.expectEqual(@as(usize, 32), o.get("trace").?.string.len);
    try testing.expectEqual(@as(usize, 16), o.get("span").?.string.len);
}

test "jsonl: a text the record's limit cut ends in … inside its string" {
    const io = testing.io;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var sink: JsonlSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{ .max_record = .literal("1KiB") });
    defer logger.deinit(io);
    const long: [2000]u8 = @splat('"');
    logger.scoped(.t).info(io, "long", .{ .body = @as([]const u8, &long) });
    try testing.expectEqual(@as(u64, 1), logger.status().cut.raw());
    const line = out.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const parsed = try strand.json.parseStdValue(testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    const body = parsed.value.object.get("body").?.string;
    try testing.expect(std.mem.endsWith(u8, body, "\"…"));
    try testing.expect(body.len > 100 and body.len < 1024);
    for (body[0 .. body.len - "…".len]) |b| try testing.expectEqual(@as(u8, '"'), b);
}

fn readBack(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const io = testing.io;
    const bytes = try gpa.alloc(u8, gen.intRange(s, usize, 0, 300));
    _ = gen.bytesInto(s, bytes);
    const words = try gen.string(s, gpa, .{});
    const n = gen.int(s, i64);
    const u = gen.int(s, u64);
    const f = gen.float(s, f64);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var sink: JsonlSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{ .max_record = .literal("1KiB") });
    defer logger.deinit(io);
    logger.scoped(.fuzz).info(io, "read back", .{ .bytes = @as([]const u8, bytes), .words = @as([]const u8, words), .n = n, .u = u, .f = f });
    const line = out.written();
    // One line, whatever the bytes.
    try testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    for (line[0 .. line.len - 1]) |b| try testing.expect(b >= 0x20);
    const parsed = try strand.json.parseStdValue(gpa, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("read back", o.get("msg").?.string);
    try testing.expectEqual(n, o.get("n").?.integer);
    try testing.expectEqual(u, try unsigned(o.get("u").?));
    try expectFloat(f, o.get("f").?);
    const cut = logger.status().cut.raw() != 0;
    inline for (.{ .{ "bytes", bytes }, .{ "words", words } }) |pair| {
        const got = o.get(pair[0]).?.string;
        try testing.expect(std.unicode.utf8ValidateSlice(got));
        if (!cut and std.unicode.utf8ValidateSlice(pair[1])) try testing.expectEqualStrings(pair[1], got);
    }
}

/// A u64 as std's reader gives it: an integer where it fits an i64, else its digits.
fn unsigned(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |i| @intCast(i),
        .number_string => |digits| std.fmt.parseInt(u64, digits, 10),
        else => error.TestUnexpectedResult,
    };
}

/// A float read back: the same number, or for one that is not finite, its name.
fn expectFloat(f: f64, v: std.json.Value) !void {
    if (std.math.isNan(f)) return testing.expectEqualStrings("NaN", v.string);
    if (std.math.isInf(f)) return testing.expectEqualStrings(if (f > 0) "Infinity" else "-Infinity", v.string);
    const got: f64 = switch (v) {
        .float => |g| g,
        .integer => |i| @floatFromInt(i),
        .number_string => |digits| try std.fmt.parseFloat(f64, digits),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(f, got);
}

test "jsonl: whatever bytes the fields hold, one line strand reads back, numbers and texts as written" {
    try shakedown.check(testing.allocator, {}, readBack, .{ .cases = 500, .seed = 0x15e1 });
}

test "jsonl: a file appended to, opened again by its path after a rotation, and an open that fails counted until one succeeds" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "logs", .default_dir);
    // A file already there is appended to.
    {
        const file = try tmp.dir.createFile(io, "logs/app.jsonl", .{});
        defer file.close(io);
        var w = file.writer(io, &.{});
        try w.interface.writeAll("{\"before\":true}\n");
    }
    var buffer: [256]u8 = undefined;
    var sink: JsonlSink = try .open(io, tmp.dir, "logs/app.jsonl", &buffer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    const log = logger.scoped(.app);
    log.info(io, "one", .{});
    // Each record is in the file when its call returns, for a reader following it or a crash.
    {
        const now = try tmp.dir.readFileAlloc(io, "logs/app.jsonl", gpa, .limited(4096));
        defer gpa.free(now);
        try testing.expectEqual(@as(usize, 2), std.mem.count(u8, now, "\n"));
    }
    // Rotated: renamed aside, then the program told.
    try tmp.dir.rename("logs/app.jsonl", tmp.dir, "app.jsonl.1", io);
    sink.reopen();
    log.info(io, "two", .{});
    // Rotated with no directory to open in: records fail and are counted, the cause kept.
    try tmp.dir.rename("logs/app.jsonl", tmp.dir, "app.jsonl.2", io);
    try tmp.dir.deleteTree(io, "logs");
    sink.reopen();
    log.info(io, "lost", .{});
    log.info(io, "lost again", .{});
    try testing.expectEqual(error.FileNotFound, sink.openFailure().?);
    try testing.expectEqual(@as(u64, 2), logger.sinkStatus(0).failures.raw());
    // Each record tries again, and once the directory is back the file opens.
    try tmp.dir.createDir(io, "logs", .default_dir);
    log.info(io, "three", .{});
    try testing.expectEqual(@as(?JsonlSink.OpenError, null), sink.openFailure());
    try sink.close(io);

    const first = try tmp.dir.readFileAlloc(io, "app.jsonl.1", gpa, .limited(4096));
    defer gpa.free(first);
    try testing.expect(std.mem.startsWith(u8, first, "{\"before\":true}\n{\"time\":"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, first, "\n"));
    try testing.expect(std.mem.find(u8, first, "\"msg\":\"one\"") != null);
    for ([_][2][]const u8{ .{ "app.jsonl.2", "two" }, .{ "logs/app.jsonl", "three" } }) |file| {
        const text = try tmp.dir.readFileAlloc(io, file[0], gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
        const parsed = try strand.json.parseStdValue(gpa, text[0 .. text.len - 1], .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(file[1], parsed.value.object.get("msg").?.string);
    }
}
