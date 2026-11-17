//! What a project that depends on blackbox and nothing else writes, with the build taking no
//! options: `blackbox`, and the two sinks, which every build declares. Built by `check-consumer`
//! with only the packages blackbox itself needs (aegis and almanac, strand for the sinks, chronicle
//! for the chronicle sink), so blackbox's build.zig works without any of its own development's.
const std = @import("std");
const blackbox = @import("blackbox");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    var text: blackbox.TextSink = .init(&stderr.interface, .{});
    var logger: blackbox.Logger = try .init(init.gpa, &.{&text.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.consumer).info(io, "built", .{});
    try jsonl(@import("blackbox_jsonl"), init.gpa, io);
    chronicle(@import("blackbox_chronicle"));
}

/// blackbox_jsonl's sink: a record written to a discarding writer.
fn jsonl(comptime blackbox_jsonl: type, gpa: std.mem.Allocator, io: std.Io) !void {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    var sink: blackbox_jsonl.JsonlSink = .init(&discarding.writer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.consumer).info(io, "as JSON", .{ .n = 1 });
    if (discarding.fullCount() == 0) return error.NothingWritten;
}

/// blackbox_chronicle's names: compiled, and the sink a `Sink`.
fn chronicle(comptime blackbox_chronicle: type) void {
    _ = &blackbox_chronicle.ChronicleSink.init;
    _ = &blackbox_chronicle.ChronicleSink.deinit;
    _ = &blackbox_chronicle.Journal.open;
    comptime {
        if (@FieldType(blackbox_chronicle.ChronicleSink, "sink") != blackbox.Sink) @compileError("the chronicle sink is a blackbox Sink");
    }
}
