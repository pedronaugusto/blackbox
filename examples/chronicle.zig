//! blackbox_chronicle's usage: records appended to a chronicle journal, a turn of the drain at a time.

const std = @import("std");
const blackbox = @import("blackbox");
const blackbox_chronicle = @import("blackbox_chronicle");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const path = ".zig-cache/tmp/blackbox-chronicle-example";
    // A fresh journal each run, so its count below is this run's.
    try std.Io.Dir.cwd().deleteTree(io, path);

    // --- README:chronicle ---
    const journal = try blackbox_chronicle.Journal.open(gpa, io, path, .{ .sync = .on_segment });
    defer journal.deinit(io);
    var sink: blackbox_chronicle.ChronicleSink = .init(gpa, journal, .{});
    defer sink.deinit();
    var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{ .delivery = .{ .queued = .{} } });
    defer logger.deinit(io);
    var drainer = try io.concurrent(blackbox.Logger.drain, .{ &logger, io });

    const log = logger.scoped(.jobs);
    for (0..10) |n| log.info(io, "ran", .{ .n = n });

    // Canceled, the drain appends what is queued and returns.
    drainer.cancel(io) catch |err| switch (err) {
        error.Canceled => log.info(io, "stopped", .{}),
    };
    // --- README:chronicle ---

    if ((try journal.lastSeq(io)).raw() != 11) return error.Records;
}
