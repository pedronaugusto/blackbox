//! The bound an example runs under. The tests run every example, and an example that never ends
//! holds its test step and a core with no end: a drain that never stopped spun for 45 hours under
//! a `bay dev test` whose clone was gone. Each example starts `watch` before anything else.

const std = @import("std");

/// The seconds an example may take, far above the fraction of a second each takes.
pub const seconds = 120;

/// Past `seconds`, ends the process as failed, naming the example; canceled when the example ends.
/// It writes to stderr itself, not through `std.log`: an example routes `std.log` through the very
/// logger that may be what never ends.
pub fn watch(io: std.Io, name: []const u8) void {
    // Canceled: the example ended inside its bound.
    const ended = if (io.sleep(.fromSeconds(seconds), .awake)) false else |err| switch (err) {
        error.Canceled => true,
    };
    if (ended) return;
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    report(&stderr.interface, name) catch std.process.exit(2);
    std.process.exit(1);
}

fn report(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try w.print("error: the {s} example still runs after {d} s: a loop with no exit, or a wait nobody ends\n", .{ name, seconds });
    try w.flush();
}
