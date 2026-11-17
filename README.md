# blackbox

blackbox: logging and tracing for Zig. Structured records with levels and typed fields, spans, a
`std.log` backend, and sinks; delivery at the call, or through queues a drain task renders. A
secret cannot reach a log (refused at compile time), no record is lost silently (dropped records
are counted and reported), and there is no thread-local context: a span or a producer is a value
handed where it is used. Built on aegis and almanac.

Status: in development, before 0.1.0. A program that imports `blackbox_chronicle` holds two strands,
blackbox's (a49e6c5, for its JSON writer) and chronicle's own (cb3d74c), as separate packages, until
the family pins to released versions; the same holds for xenoglyph.

## Usage

Records with typed fields, and a span written with its duration when it ends:

<!-- BEGIN GENERATED zig build docs -- records -->
```zig
const blackbox = @import("blackbox");

var text: blackbox.TextSink = .init(&out.writer, .{});
var logger: blackbox.Logger = try .init(gpa, &.{&text.sink}, .{ .level = .debug });
defer logger.deinit(io);

const log = logger.scoped(.http);
log.info(io, "listening", .{ .port = 8080, .tls = false });

var span = log.span(io, .info, "request", .{ .method = "GET", .path = "/index.html" });
span.debug(io, "cache", .{ .hit = true });
span.record(.{ .status = 200 });
span.end(io);
```
<!-- END GENERATED -->

`std.log` routed through the logger, so a library's records reach the same sinks (the program sets
`pub const std_options: std.Options = .{ .logFn = blackbox.std_log.logFn };`; std's `log_level` and
`log_scope_levels` are blackbox's compile-time floors too):

<!-- BEGIN GENERATED zig build docs -- std-log -->
```zig
const blackbox = @import("blackbox");

blackbox.std_log.install(&logger);
defer blackbox.std_log.uninstall();
std.log.scoped(.lib).info("opened {s}", .{"settings.json"});
```
<!-- END GENERATED -->

Queued delivery: a drain task renders what the shared queue and each producer's ring hold, in
time order with each ring's order kept:

<!-- BEGIN GENERATED zig build docs -- queued -->
```zig
const blackbox = @import("blackbox");

var text: blackbox.TextSink = .init(&out.writer, .{});
var logger: blackbox.Logger = try .init(gpa, &.{&text.sink}, .{ .delivery = .{ .queued = .{} } });
defer logger.deinit(io);
var drainer = try io.concurrent(blackbox.Logger.drain, .{ &logger, io });

// A task's own ring: no lock between it and the drain.
const producer = try logger.producer(io, gpa, .literal("64KiB"));
for (0..100) |i| producer.scoped(.worker).info(io, "step", .{ .i = i });
producer.release(io);

// Canceled, the drain renders what is queued and returns; later records render at the call.
drainer.cancel(io) catch |err| switch (err) {
    error.Canceled => logger.scoped(.worker).info(io, "drained", .{}),
};
```
<!-- END GENERATED -->

### JSON Lines

`blackbox_jsonl` (a module every build of blackbox declares, over strand, which is fetched with
blackbox and compiled only for a program that imports the sink) writes each record as one JSON object on one line, in the shape Go's `slog` JSON handler writes:
`time`, `level`, `scope`, `msg`, the fields as members, then `trace` and `span`. Whatever bytes a
field holds, the line is JSON (bytes that are not UTF-8 become U+FFFD), and a text the record's limit
cut ends in `…`. The sink writes to any `*std.Io.Writer`, or appends to a file it opens again on
`reopen`, for logrotate's rename-and-signal convention:

<!-- BEGIN GENERATED zig build docs -- jsonl -->
```zig
const blackbox = @import("blackbox");
const blackbox_jsonl = @import("blackbox_jsonl");

var buffer: [4096]u8 = undefined;
var json: blackbox_jsonl.JsonlSink = try .open(io, logs, "app.jsonl", &buffer, .{});
var logger: blackbox.Logger = try .init(gpa, &.{&json.sink}, .{});
defer logger.deinit(io);

const log = logger.scoped(.http);
// {"time":"…","level":"INFO","scope":"http","msg":"answered","status":200,"path":"/index.html"}
log.info(io, "answered", .{ .status = 200, .path = "/index.html" });

// After logrotate renamed the file: the next record opens app.jsonl again.
json.reopen();
log.info(io, "rotated", .{});
try json.close(io);
```
<!-- END GENERATED -->

### chronicle

`blackbox_chronicle` (declared the same way, over chronicle and strand) appends each record to a chronicle journal of `chronicle.Raw` events: the
object the JSON Lines sink writes for it, at the record's time in milliseconds. The records a turn
of the drain renders go in one `appendAll`, so a journal that syncs on every append pays one sync a
turn; a record delivered at the call is appended before the call returns. The journal is the
caller's, opened before the logger and closed after it:

<!-- BEGIN GENERATED zig build docs -- chronicle -->
```zig
const blackbox = @import("blackbox");
const blackbox_chronicle = @import("blackbox_chronicle");

const journal = try blackbox_chronicle.Journal.open(gpa, io, path, .{ .sync = .on_segment });
defer journal.deinit(io);
var sink: blackbox_chronicle.ChronicleSink = .init(gpa, journal, .{});
defer sink.deinit();
var logger: blackbox.Logger = try .init(gpa, &.{&sink.sink}, .{ .delivery = .{ .queued = .{} } });
defer logger.deinit(io);
var drainer = try io.concurrent(blackbox.Logger.drain, .{ &logger, io });

const log = logger.scoped(.jobs);
for (0..10) |n| log.info(io, "ran", .{ .n = n });

// Canceled, the drain appends what is queued and returns.
drainer.cancel(io) catch |err| switch (err) {
    error.Canceled => log.info(io, "stopped", .{}),
};
```
<!-- END GENERATED -->

A failed append loses its batch: the records are counted (`lostRecords`), the cause kept
(`appendFailure`), and the sink's failure counted by the logger (`Logger.sinkStatus`).

## Licence

MIT.
