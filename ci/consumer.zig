//! What a project that depends on blackbox and nothing else writes, plain and with `.jsonl = true`.
//! Built by `check-consumer` with only the packages blackbox itself needs (aegis and almanac, and
//! strand for blackbox_jsonl), so blackbox's build.zig works without any of its own development's;
//! `blackbox_jsonl` is imported where the build made it.
const std = @import("std");
const blackbox = @import("blackbox");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    var text: blackbox.TextSink = .init(&stderr.interface, .{});
    var logger: blackbox.Logger = try .init(init.gpa, &.{&text.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.consumer).info(io, "built", .{ .jsonl = blackbox.built_with.jsonl });
    if (blackbox.built_with.jsonl) try jsonl(@import("blackbox_jsonl"), init.gpa, io);
}

/// blackbox_jsonl's sink, in the build that has it: a record written to a discarding writer.
fn jsonl(comptime blackbox_jsonl: type, gpa: std.mem.Allocator, io: std.Io) !void {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    var sink: blackbox_jsonl.JsonlSink = .init(&discarding.writer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{});
    defer logger.deinit(io);
    logger.scoped(.consumer).info(io, "as JSON", .{ .n = 1 });
    if (discarding.fullCount() == 0) return error.NothingWritten;
}
