# blackbox

blackbox: logging and tracing for Zig. Structured records with levels and typed fields, spans, a
`std.log` backend, and sinks; delivery at the call, or through queues a drain task renders. A
secret cannot reach a log (refused at compile time), no record is lost silently (dropped records
are counted and reported), and there is no thread-local context: a span or a producer is a value
handed where it is used. Built on aegis and almanac.

Status: in development, before 0.1.0.

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

## Licence

MIT.
