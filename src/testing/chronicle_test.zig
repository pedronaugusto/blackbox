//! The chronicle sink: records appended to a journal as the JSON Lines sink's objects, one batch per
//! turn of the drain, one record per call when delivery is synchronous, and a failed append lost
//! and counted.
const std = @import("std");
const testing = std.testing;
const blackbox = @import("blackbox");
const sink_module = @import("blackbox_chronicle");
const ChronicleSink = sink_module.ChronicleSink;
const Journal = sink_module.Journal;
const strand = @import("strand");

/// A journal's directory of the test's own, removed when it ends.
const Workspace = struct {
    buffer: [96]u8 = undefined,
    path: []const u8 = "",

    fn init(ws: *Workspace) !void {
        var fresh: [8]u8 = undefined;
        testing.io.random(&fresh);
        ws.path = try std.mem.print(&ws.buffer, ".zig-cache/tmp/blackbox-chronicle-{x}", .{std.mem.readInt(u64, &fresh, .little)});
    }

    fn deinit(ws: *Workspace) void {
        std.Io.Dir.cwd().deleteTree(testing.io, ws.path) catch |err| std.debug.print("left {s}: {t}\n", .{ ws.path, err });
    }
};

/// The journal's records, as lines: a copy the caller frees.
fn records(journal: *Journal) !*Journal.Batch {
    return journal.copySince(testing.allocator, testing.io, .fromRaw(0));
}

test "chronicle: a turn of the drain is one batch, each record the JSON Lines sink's object" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    const journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    var sink: ChronicleSink = .init(testing.allocator, journal, .{ .commit = .atomic });
    defer sink.deinit();
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{ .delivery = .{ .queued = .{} } });
    defer logger.deinit(io);
    // The drain's state, set by hand: records queue, and `flush` renders them in one turn.
    logger.core.state.store(.running, .seq_cst);
    const log = logger.scoped(.jobs);
    // Two milliseconds apart, so each record's own time shows.
    for (0..5) |n| {
        log.info(io, "ran", .{ .n = n });
        io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    try testing.expectEqual(@as(u64, 0), (try journal.lastSeq(io)).raw());
    logger.flush(io);
    logger.core.state.store(.stopped, .seq_cst);

    const batch = try records(journal);
    defer batch.deinit();
    try testing.expectEqual(@as(usize, 5), batch.records().len);
    var last: i64 = 0;
    for (batch.records(), 0..) |r, n| {
        // Each record at its own time, and its event the object alone, with no line break.
        try testing.expect(r.at.raw() > last);
        last = r.at.raw();
        try testing.expect(std.mem.startsWith(u8, r.event.bytes, "{\"time\":") and std.mem.endsWith(u8, r.event.bytes, "}"));
        // One batch: every record names its first and last.
        try testing.expect(std.mem.find(u8, r.bytes, "\"bf\":1,\"bl\":5") != null);
        // The journal's line holds the event as the sink rendered it, its line break left out.
        try testing.expect(std.mem.findScalar(u8, r.bytes, '\n') == null);
        const parsed = try strand.json.parseStdValue(testing.allocator, r.event.bytes, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        try testing.expectEqualStrings("ran", o.get("msg").?.string);
        try testing.expectEqualStrings("jobs", o.get("scope").?.string);
        try testing.expectEqual(@as(i64, @intCast(n)), o.get("n").?.integer);
        try testing.expect(r.at.raw() > 1_700_000_000_000);
    }
    // Read back from the disk, beside the writer: the same five records, whole lines.
    const reader = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read });
    defer reader.deinit(io);
    const from_disk = try records(reader);
    defer from_disk.deinit();
    try testing.expectEqual(@as(usize, 5), from_disk.records().len);
    for (batch.records(), from_disk.records()) |a, b| try testing.expectEqualStrings(a.event.bytes, b.event.bytes);
}

test "chronicle: delivered at the call, each record is appended before the call returns" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    const journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    var sink: ChronicleSink = .init(testing.allocator, journal, .{});
    defer sink.deinit();
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    for (1..4) |n| {
        logger.scoped(.app).warn(io, "step", .{ .n = n });
        try testing.expectEqual(@as(u64, n), (try journal.lastSeq(io)).raw());
    }
}

test "chronicle: past batch_bytes, a batch is appended before the turn ends" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    const journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    // Atomic batches of more than one record carry "bf", so a batch shows.
    var sink: ChronicleSink = .init(testing.allocator, journal, .{ .batch_bytes = .literal("200B"), .commit = .atomic });
    defer sink.deinit();
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{ .delivery = .{ .queued = .{} } });
    defer logger.deinit(io);
    logger.core.state.store(.running, .seq_cst);
    const body: [150]u8 = @splat('b');
    for (0..4) |n| logger.scoped(.t).info(io, "big", .{ .n = n, .body = @as([]const u8, &body) });
    logger.flush(io);
    logger.core.state.store(.stopped, .seq_cst);
    const batch = try records(journal);
    defer batch.deinit();
    try testing.expectEqual(@as(usize, 4), batch.records().len);
    // Each record went past the bound alone, so each was its own append.
    for (batch.records()) |r| try testing.expect(std.mem.find(u8, r.bytes, "\"bf\"") == null);
}

test "chronicle: batch_bytes counts the events' own bytes, their line breaks left out" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    const journal = try Journal.open(testing.allocator, io, ws.path, .{});
    defer journal.deinit(io);
    var bytes: [blackbox.Record.header_bytes]u8 = undefined;
    blackbox.Record.writeHeader(&bytes, .{ .site = blackbox.Site.of(.info, .t, "same"), .at = .fromRaw(1_700_000_000_123_000_000) }, blackbox.Record.header_bytes, 0);
    const record = blackbox.Record.read(&bytes);
    // One event's bytes: the JSON Lines sink's line without its line break.
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try @import("blackbox_jsonl").render(&line.writer, &record, .{});
    const event = line.written().len - 1;
    // A byte more than two events: the second write stays short of it, the third reaches it.
    var sink: ChronicleSink = .init(testing.allocator, journal, .{ .batch_bytes = .fromRaw(2 * event + 1), .commit = .atomic });
    defer sink.deinit();
    try sink.sink.write(io, &record);
    try sink.sink.write(io, &record);
    try testing.expectEqual(@as(u64, 0), (try journal.lastSeq(io)).raw());
    try sink.sink.write(io, &record);
    try testing.expectEqual(@as(u64, 3), (try journal.lastSeq(io)).raw());
    const batch = try records(journal);
    defer batch.deinit();
    for (batch.records()) |r| {
        try testing.expect(std.mem.find(u8, r.bytes, "\"bf\":1,\"bl\":3") != null);
        try testing.expectEqual(event, r.event.bytes.len);
    }
}

test "chronicle: a journal that refuses appends loses the batch, counted, its cause kept" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    // A journal made, then opened again for reading only: every append is refused.
    {
        const made = try Journal.open(testing.allocator, io, ws.path, .{});
        made.deinit(io);
    }
    const journal = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read });
    defer journal.deinit(io);
    var sink: ChronicleSink = .init(testing.allocator, journal, .{});
    defer sink.deinit();
    var logger: blackbox.Logger = try .init(testing.allocator, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.app).err(io, "refused", .{});
    logger.scoped(.app).err(io, "refused again", .{});
    try testing.expectEqual(@as(u64, 2), sink.lostRecords().raw());
    try testing.expect(sink.appendFailure() != null);
    try testing.expectEqual(@as(u64, 2), logger.sinkStatus(0).failures.raw());
}

test "chronicle: a record's time in whole milliseconds, rounded down, and a failure forgotten once an append succeeds" {
    const io = testing.io;
    var ws: Workspace = .{};
    try ws.init();
    defer ws.deinit();
    {
        const made = try Journal.open(testing.allocator, io, ws.path, .{});
        made.deinit(io);
    }
    const refusing = try Journal.open(testing.allocator, io, ws.path, .{ .access = .read });
    defer refusing.deinit(io);
    var sink: ChronicleSink = .init(testing.allocator, refusing, .{});
    defer sink.deinit();
    var bytes: [blackbox.Record.header_bytes]u8 = undefined;
    blackbox.Record.writeHeader(&bytes, .{ .site = blackbox.Site.of(.info, .t, "at"), .at = .fromRaw(1_700_000_000_123_999_999) }, blackbox.Record.header_bytes, 0);
    const record = blackbox.Record.read(&bytes);
    try sink.sink.write(io, &record);
    try testing.expectError(error.WriteFailed, sink.sink.flush(io));
    try testing.expect(sink.appendFailure() != null);
    // The same sink on a journal that takes appends.
    var other: Workspace = .{};
    try other.init();
    defer other.deinit();
    const journal = try Journal.open(testing.allocator, io, other.path, .{});
    defer journal.deinit(io);
    sink.journal = journal;
    try sink.sink.write(io, &record);
    try sink.sink.flush(io);
    try testing.expectEqual(@as(?Journal.AppendError, null), sink.appendFailure());
    const batch = try records(journal);
    defer batch.deinit();
    try testing.expectEqual(@as(i64, 1_700_000_000_123), batch.records()[0].at.raw());
}
