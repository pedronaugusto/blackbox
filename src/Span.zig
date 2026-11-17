//! A span: a name, fields, a parent, start and end times. It is a value passed where it is used
//! (`span.info(io, ...)`, `span.child(...)`), never a thread-local current span, and it is written
//! once, when it ends, with its duration on the monotonic clock. Records logged through it carry its
//! trace and span ids.
//!
//! Its fields, those given at its start and those `record` adds, are encoded into its own inline
//! buffer, part of the `Span` value; past the buffer a field is cut and counted as cut. Nothing
//! allocates.
const Span = @This();
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const almanac = @import("almanac");
const Level = @import("level.zig").Level;
const ids = @import("ids.zig");
const Site = @import("Site.zig");
const encode = @import("encode.zig");
const Core = @import("Core.zig");
const default_floor = @import("options.zig").default_floor;

/// The inline buffer's bytes.
pub const field_bytes = 512;
/// Room kept for the fields `end` adds: the duration and the parent.
const end_bytes = 2 * encode.name_bytes + 9 + 1 + encode.text_header + 40;

target: Core.Target,
level: Level,
/// The scope of the call that began it.
scope: []const u8,
/// Its site; null when its level is below the compile-time floor, and it writes nothing.
site: ?*const Site,
trace_id: ids.TraceId,
id: ids.SpanId,
parent: ?ids.SpanId,
/// When it began, by the wall clock: the time its record shows.
start: almanac.Timestamp,
/// When it began, by the monotonic clock: its duration's start.
started: Monotonic,
fields: [field_bytes]u8 = undefined,
used: usize = 0,
count: u16 = 0,
cut: bool = false,
ended: bool = false,

/// The duration a span's record carries.
pub const Duration = aegis.units.Duration(.nanosecond, i96);
/// An instant of the monotonic clock, which a wall-clock step never moves.
pub const Monotonic = aegis.units.Instant(.awake, .nanosecond, i96);

fn monotonic(io: Io) Monotonic {
    return Monotonic.fromTimestamp(Io.Clock.awake.now(io), .exact);
}

pub fn begin(target: Core.Target, io: Io, level: Level, scope: []const u8, site: ?*const Site, trace_id: ?ids.TraceId, parent: ?ids.SpanId, fields: anytype) Span {
    var span: Span = .{
        .target = target,
        .level = level,
        .scope = scope,
        .site = site,
        .trace_id = trace_id orelse ids.newTrace(io),
        .id = ids.newSpan(io),
        .parent = parent,
        .start = almanac.now(io),
        .started = monotonic(io),
    };
    span.record(fields);
    return span;
}

/// Adds fields known only later, written with the span when it ends.
pub fn record(span: *Span, fields: anytype) void {
    if (span.site == null or span.ended) return;
    span.add(fields, field_bytes - end_bytes);
}

fn add(span: *Span, fields: anytype, limit: usize) void {
    const m = encode.measure(fields);
    const room = limit -| span.used;
    if (m.fixed > room) {
        if (@typeInfo(@TypeOf(fields)).@"struct".field_names.len > 0) span.cut = true;
        return;
    }
    const p = encode.put(span.fields[span.used..], fields, &m, room);
    span.used += p.used;
    span.count += p.count;
    span.cut = span.cut or p.cut;
}

/// A span within this one: its trace, this span its parent, its level.
pub fn child(span: *const Span, io: Io, comptime name: []const u8, fields: anytype) Span {
    const site: ?*const Site = if (span.site == null) null else switch (span.level) {
        inline else => |level| Site.of(level, .span, name),
    };
    return begin(span.target, io, span.level, span.scope, site, span.trace_id, span.id, fields);
}

pub fn trace(span: *const Span, io: Io, comptime message: []const u8, fields: anytype) void {
    span.log(io, .trace, message, fields);
}
pub fn debug(span: *const Span, io: Io, comptime message: []const u8, fields: anytype) void {
    span.log(io, .debug, message, fields);
}
pub fn info(span: *const Span, io: Io, comptime message: []const u8, fields: anytype) void {
    span.log(io, .info, message, fields);
}
pub fn warn(span: *const Span, io: Io, comptime message: []const u8, fields: anytype) void {
    span.log(io, .warn, message, fields);
}
pub fn err(span: *const Span, io: Io, comptime message: []const u8, fields: anytype) void {
    span.log(io, .err, message, fields);
}

/// A record in the span: its scope, trace and id.
pub fn log(span: *const Span, io: Io, comptime level: Level, comptime message: []const u8, fields: anytype) void {
    if (comptime !level.passes(default_floor)) return;
    Core.emit(span.target, io, Site.of(level, .span, message), .{ .trace = span.trace_id, .span = span.id, .scope = span.scope }, fields);
}

/// Writes the span, its fields, its duration on the monotonic clock and its parent. Ending twice is
/// a caller's mistake.
pub fn end(span: *Span, io: Io) void {
    aegis.assert.invariant(!span.ended, "blackbox: a span ended twice");
    span.ended = true;
    const site = span.site orelse return;
    const logger = span.target.of();
    if (!site.level.passes(logger.level.load(.monotonic))) return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const took = span.started.saturatingDurationTo(monotonic(io));
    span.add(.{ .duration = if (took.compare(.fromRaw(0)) == .lt) Duration.fromRaw(0) else took }, field_bytes);
    if (span.parent) |parent| span.add(.{ .parent = parent.raw() }, field_bytes);
    const raw: Core.Raw = .{
        .head = .{ .site = site, .at = span.start, .trace = span.trace_id, .span = span.id, .scope = span.scope },
        .payload = span.fields[0..span.used],
        .count = span.count,
        .cut = span.cut,
    };
    Core.deliver(span.target, io, &raw);
}
