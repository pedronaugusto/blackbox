//! blackbox_jsonl's usage: records as JSON Lines, to a file opened again after a rotation.

const std = @import("std");
const blackbox = @import("blackbox");
const blackbox_jsonl = @import("blackbox_jsonl");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, ".zig-cache/tmp/blackbox-jsonl-example");
    const logs = try dir.openDir(io, ".zig-cache/tmp/blackbox-jsonl-example", .{});
    defer logs.close(io);

    // --- README:jsonl ---
    var buffer: [4096]u8 = undefined;
    var json: blackbox_jsonl.JsonlSink = try .open(io, logs, "app.jsonl", &buffer, .{});
    var logger: blackbox.Logger = try .init(gpa, &.{&json.sink}, .{});
    defer logger.deinit(io);

    const log = logger.scoped(.http);
    // {"time":"…","level":"INFO","scope":"http","msg":"answered","status":200,"path":"/index.html"}
    log.info(io, "answered", .{ .status = 200, .path = "/index.html" });

    // After logrotate renamed the file: the next record opens app.jsonl again.
    json.reopen();
    log.info(io, "rotated", .{});
    try json.close(io);
    // --- README:jsonl ---

    const text = try logs.readFileAlloc(io, "app.jsonl", gpa, .limited(1 << 20));
    defer gpa.free(text);
    if (!std.mem.endsWith(u8, text, "\"msg\":\"rotated\"}\n")) return error.Lines;
}
