//! A producer: a ring of its owner's own, which the drain reads with no lock. Its owner logs
//! through it (`producer.scoped(.http).info(io, ...)`) and hands it on as it hands on a span, never
//! through a thread-local, so a task that moves between threads keeps it.
const Producer = @This();
const std = @import("std");
const Core = @import("Core.zig");
const scoped_ = @import("scoped.zig");

ring: *Core.Ring,

/// The calls of one scope, through this producer's ring.
pub fn scoped(p: Producer, comptime scope: @EnumLiteral()) scoped_.Scoped(scope) {
    return .{ .target = .{ .ring = p.ring } };
}

/// Gives the ring back: the drain renders what it holds and frees it, or with no drain running,
/// it is rendered and freed now. The producer is not used again.
pub fn release(p: Producer, io: std.Io) void {
    p.ring.core.release(io, p.ring);
}
