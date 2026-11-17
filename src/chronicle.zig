//! blackbox_chronicle, built with `-Dchronicle` (`.chronicle = true` from a project): the chronicle
//! sink. Each record is appended to a chronicle journal of `chronicle.Raw` events, as the JSON
//! object the JSON Lines sink writes for it (`blackbox_jsonl.render`, without its newline), at the
//! record's time in milliseconds. A reader reads an event back with strand, as any type with the
//! members it wants (`msg`, `level`, a field), or as the `Raw` it is.
//!
//! The sink keeps the records a turn of the drain renders and appends them in one `appendAll` when
//! the logger flushes it after the turn (and after each record rendered at the call), so one sync
//! serves the turn under the journal's `.always` and none is paid per record under `.on_segment`.
//! A batch that grows past `Options.batch_bytes` is appended before the turn ends. The journal is
//! the caller's: opened before the logger and finished and closed after it.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac");
const blackbox = @import("blackbox");
const blackbox_jsonl = @import("blackbox_jsonl");
const chronicle = @import("chronicle");
const Io = std.Io;
const Sink = blackbox.Sink;
const Record = blackbox.Record;

/// The journal the sink appends to: one `chronicle.Raw` event per record.
pub const Journal = chronicle.Journal(chronicle.Raw);

pub const ChronicleSink = struct {
    sink: Sink = .{ .vtable = &vtable },
    gpa: std.mem.Allocator,
    journal: *Journal,
    options: Options,
    /// The records rendered since the last append, one JSON object after another.
    bytes: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    /// What `appendAll` is given, made from `pending` when it is called.
    entries: std.ArrayList(Journal.Entry) = .empty,
    /// Records an append that failed took with it.
    lost: blackbox.Logger.Records = .fromRaw(0),
    /// Why the last append failed, until one succeeds.
    failure: ?Journal.AppendError = null,

    pub const Options = struct {
        /// The zone the events' `time` is written in; UTC when null.
        zone: ?*const almanac.TimeZone = null,
        /// What a crash inside an append leaves: a prefix of the batch, or all of it or none.
        commit: Journal.Commit = .group,
        /// Past this many bytes of records waiting, a write appends them without waiting for
        /// the logger's flush.
        batch_bytes: aegis.units.Bytes(usize) = .literal("256KiB"),
    };

    const Pending = struct { at: chronicle.Time, start: usize, len: usize };

    const vtable: Sink.VTable = .{ .write = write, .flush = flush };

    /// A sink appending to `journal`, which the caller opened and keeps open while the logger
    /// writes to it. `gpa` holds the records waiting for an append; what it allocates is kept for
    /// the next batch, so a logger at its usual rate allocates nothing once it has run a while.
    pub fn init(gpa: std.mem.Allocator, journal: *Journal, options: Options) ChronicleSink {
        return .{ .gpa = gpa, .journal = journal, .options = options };
    }

    /// Frees what the sink holds. The logger flushed it after its last record, so none waits.
    pub fn deinit(self: *ChronicleSink) void {
        aegis.assert.invariant(self.pending.items.len == 0, "blackbox: a chronicle sink freed with records not appended");
        self.bytes.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Why the last append failed, while the next has not succeeded: its records were lost
    /// (`lostRecords`) and the flush that tried counted as the sink's failure
    /// (`Logger.sinkStatus`). A journal latched by a failed write refuses every later append.
    pub fn appendFailure(self: *const ChronicleSink) ?Journal.AppendError {
        return self.failure;
    }

    /// The records failed appends took with them, in all.
    pub fn lostRecords(self: *const ChronicleSink) blackbox.Logger.Records {
        return self.lost;
    }

    fn write(sink: *Sink, io: Io, record: *const Record) Sink.WriteError!void {
        const self: *ChronicleSink = @fieldParentPtr("sink", sink);
        // No room to keep the record: it fails, and the logger counts it.
        self.pending.ensureUnusedCapacity(self.gpa, 1) catch return error.WriteFailed;
        const start = self.bytes.items.len;
        var out: Io.Writer.Allocating = .fromArrayList(self.gpa, &self.bytes);
        const rendered = blackbox_jsonl.render(&out.writer, record, .{ .zone = self.options.zone });
        self.bytes = out.toArrayList();
        rendered catch |err| {
            self.bytes.shrinkRetainingCapacity(start);
            return err;
        };
        // Without its newline: chronicle writes the line.
        const len = self.bytes.items.len - start - 1;
        self.bytes.shrinkRetainingCapacity(start + len);
        self.pending.appendAssumeCapacity(.{ .at = millis(record.at), .start = start, .len = len });
        if (self.options.batch_bytes.compare(.fromRaw(self.bytes.items.len)) != .gt) try self.append(io);
    }

    fn flush(sink: *Sink, io: Io) Sink.WriteError!void {
        const self: *ChronicleSink = @fieldParentPtr("sink", sink);
        try self.append(io);
    }

    /// Appends what waits, in one batch. A failure loses the batch, counted and kept.
    fn append(self: *ChronicleSink, io: Io) Sink.WriteError!void {
        if (self.pending.items.len == 0) return;
        defer {
            self.pending.clearRetainingCapacity();
            self.bytes.clearRetainingCapacity();
        }
        self.entries.clearRetainingCapacity();
        self.entries.ensureTotalCapacity(self.gpa, self.pending.items.len) catch return self.lose(error.OutOfMemory);
        for (self.pending.items) |p| self.entries.appendAssumeCapacity(.{ .at = p.at, .event = .{ .bytes = self.bytes.items[p.start..][0..p.len] } });
        _ = self.journal.appendAll(io, self.entries.items, self.options.commit) catch |err| return self.lose(err);
        self.failure = null;
    }

    /// The batch waiting, lost to `err`: counted, the cause kept, the flush failed.
    fn lose(self: *ChronicleSink, err: Journal.AppendError) Sink.WriteError {
        self.lost = self.lost.add(.fromRaw(self.pending.items.len)) catch .fromRaw(std.math.maxInt(u64));
        self.failure = err;
        return if (err == error.Canceled) error.Canceled else error.WriteFailed;
    }
};

/// A record's time as chronicle keeps it, in whole milliseconds, held at the ends of its range.
fn millis(at: almanac.Timestamp) chronicle.Time {
    return at.convert(.millisecond, i64, .down) catch
        if (at.compare(.epoch) == .lt) .fromRaw(std.math.minInt(i64)) else .fromRaw(std.math.maxInt(i64));
}
