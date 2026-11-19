//! The core: a run-time level, sinks, and delivery, synchronous or queued.
//!
//! Synchronous delivery encodes a record into the core's scratch buffer and renders it to each
//! sink at the call. Queued delivery copies the encoded record into a bounded ring, the shared
//! queue behind its lock or a producer's own ring with none, and `drain`, which the program runs as
//! a task of its own, renders them: at each turn it takes what every ring holds and renders it in
//! time order, each ring's own order kept. Before `drain` starts and after it stops, a queued call
//! renders synchronously, so a call never waits for a drain that is not coming and nothing is left
//! in a ring.
//!
//! Locks, in the order they are taken: the consumer (one turn at a time), the shared queue, the
//! scratch buffer, then a sink's own. A log call never fails and never returns an error: a sink's
//! failure is counted, reported as a record to the other sinks, and the sink tried again at the
//! next record. A log call blocks cancellation for its own length, so a canceled task never
//! leaves half a record; the cancellation stays pending for its next cancellation point.
const Core = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const almanac = @import("almanac");
const Level = @import("level.zig").Level;
const ids = @import("ids.zig");
const Site = @import("Site.zig");
const Sink = @import("Sink.zig");
const Record = @import("Record.zig");
const encode = @import("encode.zig");
const queue = @import("queue.zig");

pub const Options = struct {
    level: Level = .info,
    delivery: Delivery = .sync,
    /// A record's most bytes; longer texts are cut, and marked as cut. At least 1 KiB.
    max_record: aegis.units.Bytes(u32) = .literal("16KiB"),
};

pub const Delivery = union(enum) { sync, queued: Queued };

pub const Queued = struct {
    /// The shared queue's bytes.
    capacity: aegis.units.Bytes(u32) = .literal("1MiB"),
    /// What a call does when its ring is full: wait for the drain, or drop the record and count it.
    when_full: enum { block, drop } = .block,
};

/// Counts of records, apart from every other count.
pub const RecordTag = struct {};
pub const Records = aegis.units.Count(RecordTag, u64);

/// What a core has counted.
pub const Status = struct {
    /// Records dropped because a ring was full (`when_full = .drop`).
    dropped: Records,
    /// Records with a text cut at `max_record`.
    cut: Records,
    /// Records logged through `std.log` before a core was installed.
    before_install: Records,
};

/// One sink's failures.
pub const SinkStatus = struct {
    failures: Records,
    /// The first failure's error, if any.
    first: ?anyerror,
};

/// Records logged through `std.log` with no logger installed: the `std.log` backend counts them.
pub var before_install: aegis.Atomic(Records) = .init(.fromRaw(0));

/// Where a test may make delivery let another task run (`aegis.points.yield`): between a call's
/// look at the drain's state and the step that acts on it, where a drain stopping in between is
/// what the locked recheck and the producer's second look are for. Inert outside a test build.
pub const Point = enum {
    /// A call found the drain running and has not yet taken the shared queue's lock.
    queued_after_state_check,
    /// A producer found the drain running and has not yet published its record.
    ring_after_state_check,
};

const DrainState = enum(u8) { idle, running, stopped };
const Sleep = enum(u8) { awake, asleep };
const ErrorCode = enum(u16) { none = 0, _ };
const Health = enum(u8) { healthy, failing };

/// A sink and its record of failures.
const Slot = struct {
    sink: aegis.BlockingGuarded(*Sink),
    failures: aegis.Atomic(Records) = .init(.fromRaw(0)),
    first: aegis.Atomic(ErrorCode) = .init(.none),
    health: aegis.Atomic(Health) = .init(.healthy),
};

/// The shared queue and the rings the drain reads.
const Shared = struct {
    bytes: []u8,
    head: u64 = 0,
    tail: u64 = 0,
    rings: std.ArrayList(*Ring) = .empty,
};

/// The drain's side: a copy of the shared queue taken at each turn, and each source's place.
const Consumer = struct {
    local: []u8,
    sources: std.ArrayList(Source) = .empty,
    released: std.ArrayList(*Ring) = .empty,
};

/// Records to render in a turn: the shared queue's copy, or a producer's ring up to the tail seen.
const Source = struct {
    ring: ?*Ring,
    bytes: []const u8,
    head: u64,
    tail: u64,
};

gpa: Allocator,
slots: []Slot,
options: Options,
level: aegis.Atomic(Level),
scratch: aegis.BlockingGuarded([]u8),
shared: aegis.BlockingGuarded(Shared),
consumer: aegis.BlockingGuarded(Consumer),
/// The drain waits on it for records.
work: aegis.Condition = .init(),
/// A call waits on it for room in a full ring.
room: aegis.Condition = .init(),
state: aegis.Atomic(DrainState) = .init(.idle),
sleep: aegis.Atomic(Sleep) = .init(.awake),
dropped: aegis.Atomic(Records) = .init(.fromRaw(0)),
dropped_reported: aegis.Atomic(Records) = .init(.fromRaw(0)),
cut: aegis.Atomic(Records) = .init(.fromRaw(0)),

pub fn init(gpa: Allocator, sinks: []const *Sink, options: Options) error{OutOfMemory}!Core {
    aegis.assert.invariant(options.max_record.compare(.literal("1KiB")) != .lt, "blackbox: max_record is at least 1 KiB");
    const slots = try gpa.alloc(Slot, sinks.len);
    errdefer gpa.free(slots);
    for (slots, sinks) |*slot, sink| slot.* = .{ .sink = .init(sink) };
    const scratch = try gpa.alloc(u8, options.max_record.raw());
    errdefer gpa.free(scratch);
    const capacity: usize = switch (options.delivery) {
        .sync => 0,
        .queued => |q| queue.aligned(@max(q.capacity.raw(), options.max_record.raw())),
    };
    const ring = try gpa.alloc(u8, capacity);
    errdefer gpa.free(ring);
    const local = try gpa.alloc(u8, capacity);
    errdefer gpa.free(local);
    // The shared queue is always a source of the drain's turns.
    var sources: std.ArrayList(Source) = try .initCapacity(gpa, 1);
    errdefer sources.deinit(gpa);
    return .{
        .gpa = gpa,
        .slots = slots,
        .options = options,
        .level = .init(options.level),
        .scratch = .init(scratch),
        .shared = .init(.{ .bytes = ring }),
        .consumer = .init(.{ .local = local, .sources = sources }),
    };
}

/// Frees the core. Asserts the drain is not running and every producer was released.
pub fn deinit(core: *Core, io: Io) void {
    _ = io;
    aegis.assert.invariant(core.state.load(.acquire) != .running, "blackbox: the core's drain still runs at deinit");
    const shared = core.shared.teardown();
    aegis.assert.invariant(shared.rings.items.len == 0, "blackbox: a producer was not released before deinit");
    shared.rings.deinit(core.gpa);
    core.gpa.free(shared.bytes);
    const consumer = core.consumer.teardown();
    consumer.sources.deinit(core.gpa);
    consumer.released.deinit(core.gpa);
    core.gpa.free(consumer.local);
    core.gpa.free(core.scratch.teardown().*);
    core.gpa.free(core.slots);
    core.* = undefined;
}

pub fn setLevel(core: *Core, level: Level) void {
    core.level.store(level, .monotonic);
}

/// A ring of a task's own, of `capacity` bytes (at least `max_record`), which the drain reads with no
/// lock.
pub fn addRing(core: *Core, io: Io, gpa: Allocator, capacity: aegis.units.Bytes(u32)) error{OutOfMemory}!*Ring {
    const r = try Ring.create(core, gpa, queue.aligned(@max(capacity.raw(), core.options.max_record.raw())));
    errdefer r.destroy();
    // Room for the drain's view of it is made before the drain can see it.
    var consumer = core.consumer.acquireUncancelable(io);
    defer consumer.deinit(io);
    var shared = core.shared.acquireUncancelable(io);
    defer shared.deinit(io);
    const count = shared.value().rings.items.len + 1;
    try consumer.value().sources.ensureTotalCapacity(core.gpa, count + 1);
    try consumer.value().released.ensureTotalCapacity(core.gpa, count);
    try shared.value().rings.append(core.gpa, r);
    return r;
}

pub fn status(core: *const Core) Status {
    return .{
        .dropped = core.dropped.load(.monotonic),
        .cut = core.cut.load(.monotonic),
        .before_install = before_install.load(.monotonic),
    };
}

/// Sink `index`'s failures, in the order the sinks were given.
pub fn sinkStatus(core: *const Core, index: usize) SinkStatus {
    const slot = &core.slots[index];
    const code = slot.first.load(.monotonic);
    return .{
        .failures = slot.failures.load(.monotonic),
        .first = if (code == .none) null else @errorFromInt(@backingInt(code)),
    };
}

/// Where a call's record goes: the core (the shared queue when queued), or a producer's ring.
pub const Target = union(enum) {
    core: *Core,
    ring: *Ring,

    pub fn of(target: Target) *Core {
        return switch (target) {
            .core => |c| c,
            .ring => |r| r.core,
        };
    }
};

/// What a call adds to its site.
pub const Context = struct {
    trace: ?ids.TraceId = null,
    span: ?ids.SpanId = null,
    scope: ?[]const u8 = null,
};

/// One call: its record encoded and delivered, if its level passes the core's.
pub fn emit(target: Target, io: Io, site: *const Site, context: Context, fields: anytype) void {
    const core = target.of();
    if (!site.level.passes(core.level.load(.monotonic))) return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const head: Record.Head = .{ .site = site, .at = almanac.now(io), .trace = context.trace, .span = context.span, .scope = context.scope };
    const m = encode.measure(fields);
    const encoded: Encoded(@TypeOf(fields)) = .{ .head = head, .fields = fields, .measure = &m, .limit = core.payloadLimit() };
    deliver(target, io, &encoded);
}

/// A record ready to write (`len` and `write`), to where its target's delivery takes it. The caller
/// has checked its level and blocked cancellation.
pub fn deliver(target: Target, io: Io, encoded: anytype) void {
    const core = target.of();
    switch (core.options.delivery) {
        .sync => core.renderNow(io, encoded),
        .queued => switch (target) {
            .core => core.enqueue(io, encoded),
            .ring => |r| r.push(io, encoded),
        },
    }
}

/// A record whose fields were encoded before: a span's.
pub const Raw = struct {
    head: Record.Head,
    payload: []const u8,
    count: u16,
    cut: bool,

    pub fn len(r: *const Raw) usize {
        return Record.header_bytes + r.payload.len;
    }

    pub fn write(r: *const Raw, dest: []u8) struct { used: usize, cut: bool } {
        @memcpy(dest[Record.header_bytes..][0..r.payload.len], r.payload);
        Record.writeHeader(dest[0..Record.header_bytes], r.head, r.len(), r.count);
        return .{ .used = r.len(), .cut = r.cut };
    }
};

fn payloadLimit(core: *const Core) usize {
    const limit = core.options.max_record.sub(.fromRaw(Record.header_bytes)) catch aegis.assert.never("max_record is at least 1 KiB, past a header");
    return limit.raw();
}

/// A record ready to be written wherever it goes.
pub fn Encoded(comptime Fields: type) type {
    return struct {
        head: Record.Head,
        fields: Fields,
        measure: *const encode.Measure(Fields),
        limit: usize,

        /// Its bytes in all.
        pub fn len(e: *const @This()) usize {
            return Record.header_bytes + e.measure.size(e.limit);
        }

        /// Writes it into `dest` (`len` bytes at least); returns the bytes used and whether a text
        /// was cut.
        pub fn write(e: *const @This(), dest: []u8) struct { used: usize, cut: bool } {
            const p = encode.put(dest[Record.header_bytes..], e.fields, e.measure, e.limit);
            const used = Record.header_bytes + p.used;
            Record.writeHeader(dest[0..Record.header_bytes], e.head, used, p.count);
            return .{ .used = used, .cut = p.cut };
        }
    };
}

/// Renders a record at the call, through the scratch buffer.
pub fn renderNow(core: *Core, io: Io, encoded: anytype) void {
    {
        var scratch = core.scratch.acquireUncancelable(io);
        defer scratch.deinit(io);
        const w = encoded.write(scratch.value().*);
        if (w.cut) core.countCut();
        const record = Record.read(scratch.value().*[0..w.used]);
        core.renderAll(io, &record);
    }
    core.flushSinks(io);
}

pub fn countCut(core: *Core) void {
    _ = core.cut.fetchAddWrapping(.fromRaw(1), .monotonic);
}

pub fn countDropped(core: *Core) void {
    _ = core.dropped.fetchAddWrapping(.fromRaw(1), .monotonic);
}

/// Into the shared queue, or rendered at the call when no drain runs.
fn enqueue(core: *Core, io: Io, encoded: anytype) void {
    if (core.state.load(.seq_cst) != .running) return core.renderAfterQueued(io, encoded);
    aegis.points.yield(Point.queued_after_state_check);
    const len = encoded.len();
    var shared = core.shared.acquireUncancelable(io);
    while (true) {
        const s = shared.value();
        if (core.state.load(.seq_cst) != .running) {
            shared.deinit(io);
            return core.renderAfterQueued(io, encoded);
        }
        if (queue.place(s.bytes.len, s.head, s.tail, len)) |p| {
            if (p.skipped) queue.markSkip(s.bytes, s.tail);
            const w = encoded.write(s.bytes[p.offset..][0..len]);
            if (w.cut) core.countCut();
            s.tail = p.start + queue.aligned(w.used);
            break;
        }
        switch (core.options.delivery.queued.when_full) {
            .drop => {
                core.countDropped();
                shared.deinit(io);
                return;
            },
            .block => {
                core.work.signal(io);
                if (!core.waitRoom(&shared, io)) {
                    core.countDropped();
                    shared.deinit(io);
                    return;
                }
            },
        }
    }
    core.work.signal(io);
    shared.deinit(io);
}

/// Rendered at the call once no drain runs, after what the queues still hold: a drain that stopped
/// may not have taken its last turn yet, and the caller's own records queued before this one come
/// first. Once the drain stopped, its last turn has rendered them or this turn does.
fn renderAfterQueued(core: *Core, io: Io, encoded: anytype) void {
    core.turn(io);
    core.renderNow(io, encoded);
}

/// Wakes the drain if it sleeps: called by a producer after it writes, with no lock held.
pub fn wake(core: *Core, io: Io) void {
    if (core.sleep.load(.seq_cst) != .asleep) return;
    var shared = core.shared.acquireUncancelable(io);
    defer shared.deinit(io);
    core.work.signal(io);
}

/// Whether the drain runs: what a producer reads after it writes, to learn whether the drain will
/// see what it wrote.
pub fn draining(core: *const Core) bool {
    return core.state.load(.seq_cst) == .running;
}

/// What a wait for room in a full ring came to.
pub const Room = enum {
    /// The record fits now.
    fits,
    /// The drain stopped: the caller renders at the call.
    stopped,
    /// No wait was possible (the condition's waiter limit): the caller drops the record.
    refused,
};

/// Waits for room in a full producer's ring while the drain runs.
pub fn waitForRoom(core: *Core, io: Io, p: *Ring, len: usize) Room {
    var shared = core.shared.acquireUncancelable(io);
    defer shared.deinit(io);
    while (core.state.load(.seq_cst) == .running) {
        if (p.fits(len)) return .fits;
        core.work.signal(io);
        if (!core.waitRoom(&shared, io)) return .refused;
    }
    return .stopped;
}

/// Waits on `room` with the shared queue's lock held; false when the waiter limit refuses the wait.
fn waitRoom(core: *Core, shared: *aegis.BlockingGuarded(Shared).Guard, io: Io) bool {
    shared.waitUncancelable(&core.room, io, .none) catch |err| switch (err) {
        error.Timeout => aegis.assert.never("blackbox: a wait with no deadline timed out"),
        error.WaiterLimit => return false,
    };
    return true;
}

/// Renders a producer's ring with no drain to read it: after the drain stopped, its owner's.
pub fn renderOwn(core: *Core, io: Io, p: *Ring) void {
    var consumer = core.consumer.acquireUncancelable(io);
    defer consumer.deinit(io);
    var rendered = false;
    while (p.next()) |bytes| {
        const record = Record.read(bytes.record);
        core.renderAll(io, &record);
        p.consumed(bytes.after);
        rendered = true;
    }
    if (rendered) core.flushSinks(io);
}

/// Releases a producer: the drain renders what it holds and frees it, or with no drain running,
/// its owner does now.
pub fn release(core: *Core, io: Io, p: *Ring) void {
    {
        var shared = core.shared.acquireUncancelable(io);
        defer shared.deinit(io);
        if (core.state.load(.seq_cst) == .running) {
            p.released = true;
            core.work.signal(io);
            return;
        }
    }
    core.renderOwn(io, p);
    {
        var shared = core.shared.acquireUncancelable(io);
        defer shared.deinit(io);
        const list = &shared.value().rings;
        for (list.items, 0..) |item, i| if (item == p) {
            _ = list.swapRemove(i);
            break;
        };
    }
    p.destroy();
}

/// Renders queued records until canceled; then renders what was queued, marks itself stopped
/// (later calls render at the call) and returns.
pub fn drain(core: *Core, io: Io) Io.Cancelable!void {
    const before = core.state.swap(.running, .seq_cst);
    aegis.assert.invariant(before == .idle, "blackbox: a core is drained once");
    while (true) {
        core.turn(io);
        var shared = core.shared.acquireUncancelable(io);
        core.sleep.store(.asleep, .seq_cst);
        if (!core.pending(shared.value())) {
            shared.wait(&core.work, io, .none) catch |err| switch (err) {
                error.Canceled => {
                    core.sleep.store(.awake, .seq_cst);
                    core.state.store(.stopped, .seq_cst);
                    core.room.broadcast(io);
                    shared.deinit(io);
                    core.turn(io);
                    return error.Canceled;
                },
                error.Timeout => aegis.assert.never("blackbox: a wait with no deadline timed out"),
                error.WaiterLimit => aegis.assert.never("blackbox: the drain is the one task waiting for work"),
            };
        }
        core.sleep.store(.awake, .seq_cst);
        shared.deinit(io);
    }
}

/// Whether any ring holds a record; with the shared queue's lock held.
fn pending(core: *const Core, shared: *const Shared) bool {
    _ = core;
    if (shared.head != shared.tail) return true;
    for (shared.rings.items) |p| if (p.holds() or p.released) return true;
    return false;
}

/// Renders what is queued now, then flushes every sink.
pub fn flush(core: *Core, io: Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    core.turn(io);
    core.flushSinks(io);
}

/// Has every sink hand on what it buffered: after a turn, a record rendered at the call, or a
/// producer's own records, so a sink may batch what one of those renders (the chronicle sink's one
/// append per turn) and each record has been handed on when what rendered it returns.
fn flushSinks(core: *Core, io: Io) void {
    for (core.slots) |*slot| {
        const result = blk: {
            var sink = slot.sink.acquireUncancelable(io);
            defer sink.deinit(io);
            break :blk sink.value().*.flush(io);
        };
        result catch |err| core.failed(io, slot, err);
    }
}

/// One turn of the drain: every record queued now, in time order, each ring's own order kept.
fn turn(core: *Core, io: Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var consumer_guard = core.consumer.acquireUncancelable(io);
    defer consumer_guard.deinit(io);
    const consumer = consumer_guard.value();
    consumer.sources.clearRetainingCapacity();
    consumer.released.clearRetainingCapacity();
    {
        var shared_guard = core.shared.acquireUncancelable(io);
        defer shared_guard.deinit(io);
        const shared = shared_guard.value();
        // The shared queue's records, copied out so its lock is not held while sinks write.
        var copied: usize = 0;
        var head = shared.head;
        while (head != shared.tail) {
            const r = queue.at(shared.bytes, head);
            @memcpy(consumer.local[copied..][0..r.record.len], r.record);
            copied += queue.aligned(r.record.len);
            head = r.after;
        }
        shared.head = head;
        if (copied > 0) core.room.broadcast(io);
        consumer.sources.appendAssumeCapacity(.{ .ring = null, .bytes = consumer.local, .head = 0, .tail = copied });
        for (shared.rings.items) |p| {
            // A released producer writes no more: what it holds now is all it will hold.
            if (p.released) consumer.released.appendAssumeCapacity(p);
            consumer.sources.appendAssumeCapacity(.{ .ring = p, .bytes = p.bytes, .head = p.headPosition(), .tail = p.tailPosition() });
        }
    }
    var rendered = core.reportDropped(io);
    const sources = consumer.sources.items;
    while (true) {
        var pick: ?usize = null;
        var earliest: almanac.Timestamp = undefined;
        for (sources, 0..) |*s, i| {
            if (s.head == s.tail) continue;
            const at = Record.timeOf(recordAt(s).record);
            if (pick == null or at.compare(earliest) == .lt) {
                pick = i;
                earliest = at;
            }
        }
        const i = pick orelse break;
        const s = &sources[i];
        const r = recordAt(s);
        const record = Record.read(r.record);
        core.renderAll(io, &record);
        s.head = r.after;
        if (s.ring) |p| p.consumed(r.after);
        rendered = true;
    }
    if (rendered) core.flushSinks(io);
    if (sources.len > 1) {
        var shared_guard = core.shared.acquireUncancelable(io);
        defer shared_guard.deinit(io);
        core.room.broadcast(io);
        const list = &shared_guard.value().rings;
        for (consumer.released.items) |p| {
            for (list.items, 0..) |item, j| if (item == p) {
                _ = list.swapRemove(j);
                break;
            };
        }
    }
    for (consumer.released.items) |p| p.destroy();
}

/// The record at a source's head, and the position after it. A turn reads a source until its head
/// is its tail, so a record must be whole and end at the tail at most: one that ran past it (a
/// length word the writer never wrote, read as zero, skips a lap each time) would keep the turn
/// rendering with no end. It stops here, named, instead.
fn recordAt(s: *const Source) struct { record: []const u8, after: u64 } {
    const r: struct { record: []const u8, after: u64 } = if (s.ring == null) blk: {
        const len = Record.lengthOf(s.bytes[@intCast(s.head)..]);
        break :blk .{ .record = s.bytes[@intCast(s.head)..][0..len], .after = s.head + queue.aligned(len) };
    } else blk: {
        const at = queue.at(s.bytes, s.head);
        break :blk .{ .record = at.record, .after = at.after };
    };
    aegis.assert.invariant(r.record.len >= Record.header_bytes and r.after <= s.tail, "blackbox: a queued record runs past what its writer published");
    return .{ .record = r.record, .after = r.after };
}

const dropped_site = Site.of(.warn, .blackbox, "records dropped");
const failed_site = Site.of(.err, .blackbox, "sink failed");

/// A record of the drops since the last one, when there were any; whether it wrote one.
fn reportDropped(core: *Core, io: Io) bool {
    const now = core.dropped.load(.monotonic);
    const before = core.dropped_reported.swap(now, .monotonic);
    if (now.eql(before)) return false;
    const since = now.sub(before) catch aegis.assert.never("blackbox: the dropped count only grows");
    core.renderInternal(io, dropped_site, .{ .dropped = since.raw() }, null);
    return true;
}

/// A record of blackbox's own, rendered at once to every sink but `skip`.
fn renderInternal(core: *Core, io: Io, site: *const Site, fields: anytype, skip: ?usize) void {
    var bytes: [Record.header_bytes + 256]u8 = undefined;
    const m = encode.measure(fields);
    const p = encode.put(bytes[Record.header_bytes..], fields, &m, 256);
    Record.writeHeader(bytes[0..Record.header_bytes], .{ .site = site, .at = almanac.now(io) }, Record.header_bytes + p.used, p.count);
    const record = Record.read(&bytes);
    for (core.slots, 0..) |*slot, i| {
        if (skip == i) continue;
        var sink = slot.sink.acquireUncancelable(io);
        defer sink.deinit(io);
        sink.value().*.write(io, &record) catch |err| core.countFailure(slot, err);
    }
}

/// Renders a record to every sink, each under its own lock.
pub fn renderAll(core: *Core, io: Io, record: *const Record) void {
    for (core.slots) |*slot| {
        const result = blk: {
            var sink = slot.sink.acquireUncancelable(io);
            defer sink.deinit(io);
            break :blk sink.value().*.write(io, record);
        };
        if (result) |_| {
            slot.health.store(.healthy, .monotonic);
        } else |err| core.failed(io, slot, err);
    }
}

/// Counts a sink's failure.
fn countFailure(core: *Core, slot: *Slot, err: Sink.WriteError) void {
    _ = core;
    _ = slot.failures.fetchAddWrapping(.fromRaw(1), .monotonic);
    _ = slot.first.cmpxchgStrong(.none, @fromBackingInt(@intCast(@intFromError(err))), .monotonic, .monotonic);
}

/// Counts a sink's failure; the first of a run of them is reported to the other sinks.
fn failed(core: *Core, io: Io, slot: *Slot, err: Sink.WriteError) void {
    core.countFailure(slot, err);
    if (slot.health.swap(.failing, .monotonic) == .failing) return;
    const index = (@intFromPtr(slot) - @intFromPtr(core.slots.ptr)) / @sizeOf(Slot);
    core.renderInternal(io, failed_site, .{ .sink = index, .@"error" = err }, index);
}

/// A task's own ring: its owner writes it and the drain reads it, with no lock. The tail is the
/// owner's, the head the drain's; each publishes its own with a release store and reads the
/// other's with an acquire load.
pub const Ring = struct {
    core: *Core,
    gpa: Allocator,
    bytes: []u8,
    /// The drain's: what it has rendered.
    head: aegis.Atomic(Position) = .init(.fromRaw(0)),
    /// The owner's: what it has written.
    tail: aegis.Atomic(Position) = .init(.fromRaw(0)),
    /// Set by `release`, under the shared queue's lock: the owner writes no more.
    released: bool = false,

    /// A position in a ring: bytes ever written to it.
    pub const Position = aegis.units.Bytes(u64);

    pub fn create(core: *Core, gpa: Allocator, capacity: usize) error{OutOfMemory}!*Ring {
        const r = try gpa.create(Ring);
        errdefer gpa.destroy(r);
        r.* = .{ .core = core, .gpa = gpa, .bytes = try gpa.alloc(u8, capacity) };
        return r;
    }

    pub fn destroy(r: *Ring) void {
        const gpa = r.gpa;
        gpa.free(r.bytes);
        gpa.destroy(r);
    }

    /// Writes a record into the ring, or with no drain running renders it at the call.
    pub fn push(r: *Ring, io: Io, encoded: anytype) void {
        const core = r.core;
        if (!core.draining()) {
            if (r.holds()) core.renderOwn(io, r);
            return core.renderNow(io, encoded);
        }
        const len = encoded.len();
        while (true) {
            const head = r.head.load(.acquire).raw();
            const tail = r.tail.load(.monotonic).raw();
            if (queue.place(r.bytes.len, head, tail, len)) |place| {
                if (place.skipped) queue.markSkip(r.bytes, tail);
                const w = encoded.write(r.bytes[place.offset..][0..len]);
                if (w.cut) core.countCut();
                aegis.points.yield(Point.ring_after_state_check);
                r.tail.store(.fromRaw(place.start + queue.aligned(w.used)), .seq_cst);
                break;
            }
            switch (core.options.delivery.queued.when_full) {
                .drop => return core.countDropped(),
                .block => switch (core.waitForRoom(io, r, len)) {
                    .fits => {},
                    .refused => return core.countDropped(),
                    .stopped => {
                        core.renderOwn(io, r);
                        return core.renderNow(io, encoded);
                    },
                },
            }
        }
        core.wake(io);
        // A drain that stopped after this record was written may not have seen it.
        if (!core.draining()) core.renderOwn(io, r);
    }

    /// Whether a record of `len` bytes fits now.
    pub fn fits(r: *const Ring, len: usize) bool {
        return queue.place(r.bytes.len, r.head.load(.acquire).raw(), r.tail.load(.monotonic).raw(), len) != null;
    }

    /// Whether the ring holds a record the drain has not rendered.
    pub fn holds(r: *const Ring) bool {
        return !r.head.load(.seq_cst).eql(r.tail.load(.seq_cst));
    }

    pub fn headPosition(r: *const Ring) u64 {
        return r.head.load(.monotonic).raw();
    }

    pub fn tailPosition(r: *const Ring) u64 {
        return r.tail.load(.seq_cst).raw();
    }

    /// The next record to render, for the one task reading the ring.
    pub fn next(r: *const Ring) ?@TypeOf(queue.at(r.bytes, 0)) {
        if (!r.holds()) return null;
        return queue.at(r.bytes, r.head.load(.monotonic).raw());
    }

    /// Records up to `after` are rendered: their room is the owner's again.
    pub fn consumed(r: *Ring, after: u64) void {
        r.head.store(.fromRaw(after), .release);
    }
};
