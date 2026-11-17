//! A sink renders records. An implementation embeds a `Sink` and recovers itself from it with
//! `@fieldParentPtr`; the logger calls it under that sink's own lock, one record at a time.
const Sink = @This();
const std = @import("std");
const Record = @import("Record.zig");

vtable: *const VTable,

pub const VTable = struct {
    /// Renders one record whole.
    write: *const fn (sink: *Sink, io: std.Io, record: *const Record) WriteError!void,
    /// Hands on what the sink has buffered.
    flush: *const fn (sink: *Sink, io: std.Io) WriteError!void,
};

/// A sink's failure: its writer's, or its task canceled.
pub const WriteError = std.Io.Writer.Error || std.Io.Cancelable;

pub fn write(sink: *Sink, io: std.Io, record: *const Record) WriteError!void {
    return sink.vtable.write(sink, io, record);
}

pub fn flush(sink: *Sink, io: std.Io) WriteError!void {
    return sink.vtable.flush(sink, io);
}
