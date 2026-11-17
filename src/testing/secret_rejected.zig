//! Each case logs a secret, which must not compile: build.zig names the message each is refused with.
const std = @import("std");
const aegis = @import("aegis");
const blackbox = @import("blackbox");
const case = @import("rejection_options").case;

const Config = struct { name: []const u8, key: aegis.Secret(u64) };

export fn rejected() void {
    const io = std.Options.debug_io;
    var logger: blackbox.Logger = undefined;
    const log = logger.scoped(.app);
    switch (case) {
        0 => log.info(io, "key", .{ .key = aegis.Secret(u64).init(7) }),
        1 => log.info(io, "bytes", .{ .bytes = aegis.SecretBytes.empty }),
        2 => log.info(io, "config", .{ .config = Config{ .name = "a", .key = .init(7) } }),
        3 => blackbox.std_log.logFn(.info, .app, "{any}", .{aegis.Secret(u64).init(7)}),
        else => @compileError("no such case"),
    }
}
