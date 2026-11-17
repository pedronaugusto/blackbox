//! blackbox's usage: a logger with a text sink, records with fields, a span, `std.log` routed
//! through it, and queued delivery with its drain.

const std = @import("std");
const blackbox = @import("blackbox");

pub const std_options: std.Options = .{ .logFn = blackbox.std_log.logFn };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // --- README:records ---
    var text: blackbox.TextSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&text.sink}, .{ .level = .debug });
    defer logger.deinit(io);

    const log = logger.scoped(.http);
    log.info(io, "listening", .{ .port = 8080, .tls = false });

    var span = log.span(io, .info, "request", .{ .method = "GET", .path = "/index.html" });
    span.debug(io, "cache", .{ .hit = true });
    span.record(.{ .status = 200 });
    span.end(io);
    // --- README:records ---

    // --- README:std-log ---
    blackbox.std_log.install(&logger);
    defer blackbox.std_log.uninstall();
    std.log.scoped(.lib).info("opened {s}", .{"settings.json"});
    // --- README:std-log ---

    if (std.mem.count(u8, out.written(), "\n") != 4) return error.Lines;
    try queued(gpa, io);
}

fn queued(gpa: std.mem.Allocator, io: std.Io) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // --- README:queued ---
    var text: blackbox.TextSink = .init(&out.writer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&text.sink}, .{ .delivery = .{ .queued = .{} } });
    defer logger.deinit(io);
    var drainer = try io.concurrent(blackbox.Logger.drain, .{ &logger, io });

    // A task's own ring: no lock between it and the drain.
    const producer = try logger.producer(io, gpa, .literal("64KiB"));
    for (0..100) |i| producer.scoped(.worker).info(io, "step", .{ .i = i });
    producer.release(io);

    // Canceled, the drain renders what is queued and returns; later records render at the call.
    drainer.cancel(io) catch |err| switch (err) {
        error.Canceled => logger.scoped(.worker).info(io, "drained", .{}),
    };
    // --- README:queued ---
    if (std.mem.count(u8, out.written(), "\n") != 101) return error.Lines;
}
