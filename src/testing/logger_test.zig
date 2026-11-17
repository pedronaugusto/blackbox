//! Delivery: records at the call and through queues, producers' rings, spans, the `std.log`
//! backend, sinks that fail; and under shakedown's simulated schedules, every record rendered
//! exactly once per sink or counted as dropped, in each producer's order, with the drain stopping
//! at any point.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const blackbox = @import("../blackbox.zig");
const shakedown = @import("shakedown");
const Logger = blackbox.Logger;

/// A sink that keeps what each record says, or fails when told to.
const Collect = struct {
    sink: blackbox.Sink = .{ .vtable = &vtable },
    gpa: std.mem.Allocator,
    seen: std.ArrayList(Seen) = .empty,
    lines: std.Io.Writer.Allocating,
    failing: bool = false,

    const Seen = struct { task: u64, seq: u64, level: blackbox.Level, message: []const u8, span: ?u64, trace: ?u128 };
    const vtable: blackbox.Sink.VTable = .{ .write = write, .flush = flush };

    fn init(gpa: std.mem.Allocator) Collect {
        return .{ .gpa = gpa, .lines = .init(gpa) };
    }

    fn deinit(c: *Collect) void {
        c.seen.deinit(c.gpa);
        c.lines.deinit();
    }

    fn write(sink: *blackbox.Sink, io: Io, record: *const blackbox.Record) blackbox.Sink.WriteError!void {
        _ = io;
        const c: *Collect = @fieldParentPtr("sink", sink);
        if (c.failing) return error.WriteFailed;
        var seen: Seen = .{ .task = 0, .seq = 0, .level = record.level, .message = record.message(), .span = if (record.span) |s| s.raw() else null, .trace = if (record.trace) |t| t.raw() else null };
        var it = record.fields();
        while (it.next()) |f| {
            if (std.mem.eql(u8, f.name, "task")) seen.task = f.value.uint;
            if (std.mem.eql(u8, f.name, "seq")) seen.seq = f.value.uint;
        }
        c.seen.append(c.gpa, seen) catch return error.WriteFailed;
        try @import("../sink/text.zig").render(&c.lines.writer, record, .{});
    }

    fn flush(sink: *blackbox.Sink, io: Io) blackbox.Sink.WriteError!void {
        _ = sink;
        _ = io;
    }

    fn text(c: *Collect) []const u8 {
        return c.lines.written();
    }
};

test "logger: synchronous records pass the run-time level and reach every sink" {
    const io = testing.io;
    var a: Collect = .init(testing.allocator);
    defer a.deinit();
    var b: Collect = .init(testing.allocator);
    defer b.deinit();
    var logger: Logger = try .init(testing.allocator, &.{ &a.sink, &b.sink }, .{ .level = .info });
    defer logger.deinit(io);
    const log = logger.scoped(.http);
    log.debug(io, "hidden", .{});
    log.info(io, "answered", .{ .status = 200 });
    logger.setLevel(.warn);
    log.info(io, "hidden", .{});
    log.warn(io, "slow", .{ .took_ms = 900 });
    try testing.expectEqual(@as(usize, 2), a.seen.items.len);
    try testing.expectEqual(@as(usize, 2), b.seen.items.len);
    try testing.expect(std.mem.find(u8, a.text(), " INFO  http: answered status=200\n") != null);
    try testing.expect(std.mem.find(u8, a.text(), " WARN  http: slow took_ms=900\n") != null);
}

test "logger: a failing sink is counted, reported to the others, and tried again" {
    const io = testing.io;
    var good: Collect = .init(testing.allocator);
    defer good.deinit();
    var bad: Collect = .init(testing.allocator);
    defer bad.deinit();
    bad.failing = true;
    var logger: Logger = try .init(testing.allocator, &.{ &good.sink, &bad.sink }, .{});
    defer logger.deinit(io);
    const log = logger.scoped(.app);
    log.info(io, "one", .{});
    log.info(io, "two", .{});
    try testing.expectEqual(@as(u64, 2), logger.sinkStatus(1).failures.raw());
    try testing.expectEqual(@as(?anyerror, error.WriteFailed), logger.sinkStatus(1).first);
    // The first failure of the run is reported once.
    try testing.expectEqual(@as(usize, 3), good.seen.items.len);
    try testing.expectEqualStrings("sink failed", good.seen.items[1].message);
    bad.failing = false;
    log.info(io, "three", .{});
    try testing.expectEqual(@as(usize, 1), bad.seen.items.len);
}

test "logger: a text past max_record is cut, marked and counted" {
    const io = testing.io;
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var logger: Logger = try .init(testing.allocator, &.{&c.sink}, .{ .max_record = .literal("1KiB") });
    defer logger.deinit(io);
    const long: [3000]u8 = @splat('x');
    logger.scoped(.app).info(io, "long", .{ .body = &long });
    try testing.expectEqual(@as(u64, 1), logger.status().cut.raw());
    try testing.expect(std.mem.endsWith(u8, c.text(), "x\"…\n"));
}

test "logger: spans carry their ids, late fields, a duration and their parent" {
    const io = testing.io;
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var logger: Logger = try .init(testing.allocator, &.{&c.sink}, .{});
    defer logger.deinit(io);
    const log = logger.scoped(.http);
    var span = log.span(io, .info, "request", .{ .path = "/" });
    span.info(io, "inside", .{});
    var child = span.child(io, "query", .{});
    child.end(io);
    span.record(.{ .status = 200 });
    span.end(io);
    try testing.expectEqual(@as(usize, 3), c.seen.items.len);
    const inside = c.seen.items[0];
    try testing.expectEqual(span.id.raw(), inside.span.?);
    try testing.expectEqual(span.trace_id.raw(), inside.trace.?);
    try testing.expectEqual(span.trace_id.raw(), c.seen.items[1].trace.?);
    const lines = c.text();
    try testing.expect(std.mem.find(u8, lines, "http: inside trace=") != null);
    try testing.expect(std.mem.find(u8, lines, "http: query duration=") != null);
    try testing.expect(std.mem.find(u8, lines, "parent=") != null);
    try testing.expect(std.mem.find(u8, lines, "http: request path=/ status=200 duration=") != null);
}

test "logger: a span below the floor writes nothing and still carries ids" {
    const io = testing.io;
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var logger: Logger = try .init(testing.allocator, &.{&c.sink}, .{});
    defer logger.deinit(io);
    var span = logger.scoped(.app).span(io, .trace, "quiet", .{});
    span.end(io);
    try testing.expect(span.id.raw() != 0);
    try testing.expectEqual(@as(usize, 0), c.seen.items.len);
}

test "logger: queued records render through the drain and at the call once it stops" {
    const io = testing.io;
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var logger: Logger = try .init(testing.allocator, &.{&c.sink}, .{ .delivery = .{ .queued = .{} } });
    defer logger.deinit(io);
    const log = logger.scoped(.app);
    // No drain yet: at the call.
    log.info(io, "before", .{ .seq = 0 });
    try testing.expectEqual(@as(usize, 1), c.seen.items.len);
    var drainer = try io.concurrent(Logger.drain, .{ &logger, io });
    var producer = try logger.producer(io, testing.allocator, .literal("4KiB"));
    for (1..200) |i| {
        if (i % 2 == 0) log.info(io, "shared", .{ .task = 0, .seq = i }) else producer.scoped(.app).info(io, "own", .{ .task = 1, .seq = i });
    }
    producer.release(io);
    try testing.expectError(error.Canceled, drainer.cancel(io));
    log.info(io, "after", .{ .seq = 200 });
    try testing.expectEqual(@as(usize, 201), c.seen.items.len);
    var last: [2]u64 = .{ 0, 0 };
    for (c.seen.items[1..200]) |s| {
        try testing.expect(s.seq > last[s.task]);
        last[s.task] = s.seq;
    }
}

test "logger: std.log reaches the installed logger, and is counted before" {
    const io = testing.io;
    var c: Collect = .init(testing.allocator);
    defer c.deinit();
    var logger: Logger = try .init(testing.allocator, &.{&c.sink}, .{ .level = .debug });
    defer logger.deinit(io);
    blackbox.std_log.install(&logger);
    blackbox.std_log.logFn(.info, .lib, "opened {s} in {d}ms", .{ "file", 3 });
    blackbox.std_log.uninstall();
    try testing.expectEqual(@as(usize, 1), c.seen.items.len);
    try testing.expectEqualStrings("opened file in 3ms", c.seen.items[0].message);
    try testing.expect(std.mem.find(u8, c.text(), " INFO  lib: opened file in 3ms\n") != null);
}

/// One simulated run: tasks logging through the shared queue or rings of their own, the drain
/// canceled at a point the schedule picks.
const Run = struct {
    logger: Logger,
    collect: Collect,
    tasks: usize,
    per_task: usize,
    rings: u64,
    stop_after: Io.Duration,

    fn main(run: *Run, io: Io) void {
        var drainer = io.concurrent(Logger.drain, .{ &run.logger, io }) catch @panic("no concurrency");
        var group: Io.Group = .init;
        for (0..run.tasks) |t| group.concurrent(io, task, .{ run, io, t }) catch @panic("no concurrency");
        io.sleep(run.stop_after, .awake) catch {};
        drainer.cancel(io) catch {};
        group.await(io) catch {};
    }

    fn task(run: *Run, io: Io, t: usize) void {
        const own = (run.rings >> @intCast(t)) & 1 == 1;
        const producer = if (own) run.logger.producer(io, run.collect.gpa, .literal("1KiB")) catch @panic("OOM") else null;
        for (0..run.per_task) |seq| {
            if (producer) |p| p.scoped(.sim).info(io, "r", .{ .task = t, .seq = seq }) else run.logger.scoped(.sim).info(io, "r", .{ .task = t, .seq = seq });
            if (seq % 3 == t % 3) io.sleep(.fromNanoseconds(@intCast(1000 * (seq + 1))), .awake) catch {};
        }
        if (producer) |p| p.release(io);
    }
};

test "logger: every record once per sink or counted dropped, each task's order kept, the drain stopping anywhere" {
    const gpa = testing.allocator;
    for (0..48) |seed| for ([_]bool{ false, true }) |drop| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        var run: Run = .{
            .logger = undefined,
            .collect = .init(gpa),
            .tasks = r.intRangeAtMost(usize, 1, 4),
            .per_task = r.intRangeAtMost(usize, 1, 40),
            .rings = r.int(u64),
            .stop_after = .fromNanoseconds(r.intRangeAtMost(i96, 0, 200_000)),
        };
        defer run.collect.deinit();
        run.logger = try .init(gpa, &.{&run.collect.sink}, .{ .max_record = .literal("1KiB"), .delivery = .{ .queued = .{ .capacity = .literal("1KiB"), .when_full = if (drop) .drop else .block } } });
        defer run.logger.deinit(testing.io);
        const sim = try shakedown.Sim.init(gpa, .{ .executor = .threads, .seed = seed, .yield_per_million = 200_000 });
        defer sim.deinit();
        try testing.expectEqual(shakedown.Sim.Outcome.finished, sim.run(Run.main, .{ &run, sim.io() }));
        var next: [4]u64 = @splat(0);
        var rendered: usize = 0;
        for (run.collect.seen.items) |s| {
            if (!std.mem.eql(u8, s.message, "r")) continue;
            // In order, none twice; with drops, gaps.
            try testing.expect(s.seq >= next[s.task]);
            if (!drop) try testing.expectEqual(next[s.task], s.seq);
            next[s.task] = s.seq + 1;
            rendered += 1;
        }
        const dropped = run.logger.status().dropped.raw();
        try testing.expectEqual(run.tasks * run.per_task, rendered + dropped);
        if (!drop) try testing.expectEqual(@as(u64, 0), dropped);
    };
}
