//! The byte rings records are queued in: the shared queue's, behind its lock, and each producer's,
//! which one task writes and the drain reads with no lock. A position counts every byte ever
//! written (it never wraps in practice: 2^64 bytes); its offset in the ring is the position modulo
//! the capacity. A record is whole at one offset, 8-byte aligned: one that would run past the end
//! of the ring leaves a zero length word there, and the reader skips to the ring's start.
const std = @import("std");
const Record = @import("Record.zig");

pub const alignment = 8;

/// A record's bytes in a ring, rounded up to the alignment.
pub fn aligned(len: usize) usize {
    return std.mem.alignForward(usize, len, alignment);
}

/// Where a record goes: from `start` (after a skip from `tail` when the end of the ring is too
/// short) to `end`.
pub const Place = struct {
    start: u64,
    end: u64,
    /// The offset of `start`.
    offset: usize,
    /// Whether the ring's end was skipped, leaving a zero length word at the tail's offset.
    skipped: bool,
};

/// Where a record of `len` bytes goes in a ring of `capacity` bytes read up to `head` and written
/// up to `tail`; null when it does not fit now.
pub fn place(capacity: usize, head: u64, tail: u64, len: usize) ?Place {
    const need = aligned(len);
    if (need > capacity) return null;
    const offset: usize = @intCast(tail % capacity);
    const skip: usize = if (capacity - offset >= need) 0 else capacity - offset;
    const start = tail + skip;
    const end = start + need;
    if (end - head > capacity) return null;
    return .{ .start = start, .end = end, .offset = if (skip == 0) offset else 0, .skipped = skip != 0 };
}

/// Marks the end of the ring as skipped at `tail`.
pub fn markSkip(bytes: []u8, tail: u64) void {
    const offset: usize = @intCast(tail % bytes.len);
    std.mem.writeInt(u32, bytes[offset..][0..4], 0, .little);
}

/// The record at `head`, and the position after it; `head` must be short of the tail.
pub fn at(bytes: []const u8, head: u64) struct { record: []const u8, after: u64 } {
    var pos = head;
    var offset: usize = @intCast(pos % bytes.len);
    if (std.mem.readInt(u32, bytes[offset..][0..4], .little) == 0) {
        pos += bytes.len - offset;
        offset = 0;
    }
    const len = Record.lengthOf(bytes[offset..]);
    return .{ .record = bytes[offset..][0..len], .after = pos + aligned(len) };
}

test "records stay whole across the ring's end" {
    var ring: [64]u8 = undefined;
    var head: u64 = 0;
    var tail: u64 = 0;
    // 24-byte records: the third does not fit before the end and starts at the ring's start.
    var written: usize = 0;
    var read: usize = 0;
    for (0..10) |round| {
        while (place(ring.len, head, tail, 20)) |p| {
            if (p.skipped) markSkip(&ring, tail);
            std.mem.writeInt(u32, ring[p.offset..][0..4], 20, .little);
            ring[p.offset + 4] = @truncate(written);
            tail = p.end;
            written += 1;
        }
        _ = round;
        const r = at(&ring, head);
        try std.testing.expectEqual(@as(usize, 20), r.record.len);
        try std.testing.expectEqual(@as(u8, @truncate(read)), r.record[4]);
        head = r.after;
        read += 1;
    }
    try std.testing.expect(written > 10);
}

test "a record longer than the ring never fits" {
    try std.testing.expectEqual(@as(?Place, null), place(64, 0, 0, 65));
}
