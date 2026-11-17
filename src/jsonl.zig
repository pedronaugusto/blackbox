//! blackbox_jsonl, built with `-Djsonl` (`.jsonl = true` from a project): the JSON Lines sink. A
//! record is one JSON object on one line, in the shape Go's `slog` JSON handler writes:
//!
//!   {"time":"2026-11-17T16:32:02.123Z","level":"INFO","scope":"http","msg":"answered","status":200}
//!
//! then its fields as members in their order, and `trace` and `span` as hex when it has them. Names
//! and texts are JSON strings as strand writes them (`strand.json.writeString`), bytes that are not
//! UTF-8 each written as U+FFFD, so whatever a field holds, the line is JSON and one line. A text the
//! record's limit cut ends in `…` inside its string. A float that is not finite is the string `NaN`,
//! `Infinity` or `-Infinity`, which JSON has no number for. A field named as one of the record's own
//! members is written beside it, as `slog` does: a reader keeps one of the two.
//!
//! The sink writes to any `*Io.Writer`, or to a file it opens and appends to, which `reopen` opens
//! again by its path: logrotate's convention, where the file is renamed and the program told.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac");
const blackbox = @import("blackbox");
const strand = @import("strand");
const Io = std.Io;
const Sink = blackbox.Sink;
const Record = blackbox.Record;

pub const JsonlSink = struct {
    sink: Sink = .{ .vtable = &vtable },
    output: Output,
    options: Options,
    /// Set by `reopen` from any task; the next write or flush, under the sink's lock, opens the file.
    asked: aegis.Atomic(Asked) = .init(.no),

    pub const Options = struct {
        /// The zone times are written in; UTC when null.
        zone: ?*const almanac.TimeZone = null,
    };

    const Asked = enum(u8) { no, yes };

    const Output = union(enum) {
        writer: *Io.Writer,
        file: Appended,
    };

    /// A file the sink opened and appends to.
    const Appended = struct {
        dir: aegis.own.Unowned(Io.Dir),
        path: []const u8,
        buffer: []u8,
        /// Null once an open failed, until one succeeds.
        writer: ?Io.File.Writer,
        /// Why the last open failed.
        failure: ?OpenError = null,
    };

    /// What opening the file fails with.
    pub const OpenError = Io.File.OpenError || Io.File.LengthError || Io.File.Writer.SeekError;

    const vtable: Sink.VTable = .{ .write = write, .flush = flush };

    /// A sink writing to `writer`, which its caller keeps and flushes as it likes; each record is
    /// flushed through it.
    pub fn init(writer: *Io.Writer, options: Options) JsonlSink {
        return .{ .output = .{ .writer = writer }, .options = options };
    }

    /// A sink appending to the file at `path` in `dir`, created if it is not there, through
    /// `buffer`. `dir`, `path` and `buffer` are the caller's and outlive the sink; `close` closes
    /// the file. The sink is used where it was made: it holds the file's writer.
    pub fn open(io: Io, dir: Io.Dir, path: []const u8, buffer: []u8, options: Options) OpenError!JsonlSink {
        return .{
            .output = .{ .file = .{ .dir = .of(dir), .path = path, .buffer = buffer, .writer = try append(io, dir, path, buffer) } },
            .options = options,
        };
    }

    /// Asks the sink to close its file and open its path again before its next record: after the
    /// file was renamed for rotation. Any task may ask; a sink writing to a writer has nothing to
    /// open, and ignores it.
    pub fn reopen(self: *JsonlSink) void {
        self.asked.store(.yes, .release);
    }

    /// Why the file's last open failed, while it has none open: its records fail and are counted
    /// (`Logger.sinkStatus`) until an open succeeds, which each record tries.
    pub fn openFailure(self: *const JsonlSink) ?OpenError {
        return switch (self.output) {
            .writer => null,
            .file => |f| f.failure,
        };
    }

    /// Flushes and closes the sink's file; a sink writing to a writer has none. Called once the
    /// logger no longer writes to it. The file is closed whether or not what it held was written.
    pub fn close(self: *JsonlSink, io: Io) Io.Writer.Error!void {
        switch (self.output) {
            .writer => {},
            .file => |*f| return closeFile(f, io),
        }
    }

    fn write(sink: *Sink, io: Io, record: *const Record) Sink.WriteError!void {
        const self: *JsonlSink = @fieldParentPtr("sink", sink);
        const w = try self.target(io);
        try render(w, record, self.options);
        try w.flush();
    }

    fn flush(sink: *Sink, io: Io) Sink.WriteError!void {
        const self: *JsonlSink = @fieldParentPtr("sink", sink);
        const w = try self.target(io);
        try w.flush();
    }

    /// Where a record goes now: the file opened again first if that was asked, or if the last open
    /// failed.
    fn target(self: *JsonlSink, io: Io) Io.Writer.Error!*Io.Writer {
        switch (self.output) {
            .writer => |w| return w,
            .file => |*f| {
                if (self.asked.swap(.no, .acq_rel) == .yes or f.writer == null) {
                    // What the old file holds unwritten goes to it before it closes; a failure
                    // there loses that, fails this record so it is counted, and the new file
                    // still opens.
                    const flushed = closeFile(f, io);
                    f.writer = append(io, f.dir.get(), f.path, f.buffer) catch |err| {
                        f.failure = err;
                        return error.WriteFailed;
                    };
                    f.failure = null;
                    try flushed;
                }
                return &f.writer.?.interface;
            },
        }
    }
};

/// Flushes and closes `f`'s file, if it has one open; it is closed either way.
fn closeFile(f: *JsonlSink.Appended, io: Io) Io.Writer.Error!void {
    if (f.writer) |*w| {
        const flushed = w.interface.flush();
        w.file.close(io);
        f.writer = null;
        return flushed;
    }
}

/// The file at `path`, created if it is not there, with a writer at its end.
fn append(io: Io, dir: Io.Dir, path: []const u8, buffer: []u8) JsonlSink.OpenError!Io.File.Writer {
    const file = try dir.createFile(io, path, .{ .truncate = false });
    errdefer file.close(io);
    var w = file.writer(io, buffer);
    try w.seekToUnbuffered(try file.length(io));
    return w;
}

/// One record as one JSON line, its newline included.
pub fn render(w: *Io.Writer, record: *const Record, options: JsonlSink.Options) Io.Writer.Error!void {
    try w.writeAll("{\"time\":\"");
    const offset: ?almanac.Offset = if (options.zone) |zone| zone.offsetAt(record.at) catch null else null;
    almanac.text.writeTimestamp(w, record.at, offset) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => try w.print("{d}", .{record.at.raw()}),
    };
    try w.writeAll("\",\"level\":\"");
    try w.writeAll(levelName(record.level));
    try w.writeAll("\",\"scope\":");
    try string(w, record.scope);
    try w.writeAll(",\"msg\":");
    try string(w, record.message());
    var it = record.fields();
    while (it.next()) |field| {
        try w.writeByte(',');
        try string(w, field.name);
        try w.writeByte(':');
        try value(w, field.value);
    }
    if (record.trace) |trace| {
        try w.writeAll(",\"trace\":\"");
        try w.print("{x:0>32}", .{trace.raw()});
        try w.writeByte('"');
    }
    if (record.span) |span| {
        try w.writeAll(",\"span\":\"");
        try w.print("{x:0>16}", .{span.raw()});
        try w.writeByte('"');
    }
    try w.writeAll("}\n");
}

/// A level as `slog` names its own, and `TRACE` below them.
fn levelName(level: blackbox.Level) []const u8 {
    return switch (level) {
        .trace => "TRACE",
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
}

/// A value as a JSON member's.
fn value(w: *Io.Writer, v: blackbox.Value) Io.Writer.Error!void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .uint => |n| try w.print("{d}", .{n}),
        .float => |f| {
            if (std.math.isNan(f)) return w.writeAll("\"NaN\"");
            if (std.math.isInf(f)) return w.writeAll(if (f > 0) "\"Infinity\"" else "\"-Infinity\"");
            strand.json.write(w, f, .{}) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
                else => aegis.assert.never("blackbox: strand spells every finite float"),
            };
        },
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .text => |text| {
            if (!text.cut) return string(w, text.bytes);
            // The content as strand escapes it, without its quotes, then the mark inside them.
            try w.writeByte('"');
            var inside: Inside = .{ .out = w };
            try string(&inside.writer, text.bytes);
            try w.writeAll("…\"");
        },
    }
}

/// `bytes` as one JSON string, each byte that is not UTF-8 as U+FFFD.
fn string(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    strand.json.writeString(w, bytes, .replace) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.InvalidUtf8 => aegis.assert.never("blackbox: a string written with .replace is never refused"),
    };
}

/// A writer handing on what it is given but for its first byte and its last: a JSON string's
/// content, without the quotes `writeString` puts round it. Unbuffered, so every byte reaches
/// `drain`; the last is held until another comes, and dropped at the end.
const Inside = struct {
    out: *Io.Writer,
    started: bool = false,
    held: ?u8 = null,
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Inside = @fieldParentPtr("writer", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.take(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.take(last);
        return n + last.len * splat;
    }

    fn take(self: *Inside, given: []const u8) Io.Writer.Error!void {
        var bytes = given;
        if (!self.started and bytes.len > 0) {
            self.started = true;
            bytes = bytes[1..];
        }
        if (bytes.len == 0) return;
        if (self.held) |b| try self.out.writeByte(b);
        try self.out.writeAll(bytes[0 .. bytes.len - 1]);
        self.held = bytes[bytes.len - 1];
    }
};
