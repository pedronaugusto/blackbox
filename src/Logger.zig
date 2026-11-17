//! The logger: a run-time level, sinks, and delivery, synchronous or queued (Core.zig holds the
//! machinery). A logger does not move once a drain or a producer holds it.
const Logger = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const Level = @import("level.zig").Level;
const Sink = @import("Sink.zig");
const Core = @import("Core.zig");
const Producer = @import("Producer.zig");
const scoped_ = @import("scoped.zig");

pub const Options = Core.Options;
pub const Delivery = Core.Delivery;
pub const Queued = Core.Queued;
pub const Records = Core.Records;
pub const Status = Core.Status;
pub const SinkStatus = Core.SinkStatus;

core: Core,

pub fn init(gpa: Allocator, sinks: []const *Sink, options: Options) error{OutOfMemory}!Logger {
    return .{ .core = try .init(gpa, sinks, options) };
}

/// Frees the logger. Asserts the drain is not running and every producer was released.
pub fn deinit(logger: *Logger, io: Io) void {
    logger.core.deinit(io);
}

/// The calls of one scope.
pub fn scoped(logger: *Logger, comptime scope: @EnumLiteral()) scoped_.Scoped(scope) {
    return .{ .target = .{ .core = &logger.core } };
}

pub fn setLevel(logger: *Logger, level: Level) void {
    logger.core.setLevel(level);
}

/// A ring of the calling task's own, of `capacity` bytes (at least `max_record`), which the drain
/// reads with no lock. The task logs through it and hands it on as it hands on a span; `release`
/// gives it back.
pub fn producer(logger: *Logger, io: Io, gpa: Allocator, capacity: aegis.units.Bytes(u32)) error{OutOfMemory}!Producer {
    return .{ .ring = try logger.core.addRing(io, gpa, capacity) };
}

/// Renders queued records until canceled; then renders what was queued, marks itself stopped
/// (later calls render at the call) and returns.
pub fn drain(logger: *Logger, io: Io) Io.Cancelable!void {
    return logger.core.drain(io);
}

/// Renders what is queued now, then flushes every sink.
pub fn flush(logger: *Logger, io: Io) void {
    logger.core.flush(io);
}

pub fn status(logger: *const Logger) Status {
    return logger.core.status();
}

/// Sink `index`'s failures, in the order the sinks were given.
pub fn sinkStatus(logger: *const Logger, index: usize) SinkStatus {
    return logger.core.sinkStatus(index);
}
