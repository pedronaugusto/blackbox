# Design

blackbox is logging and tracing for Zig: structured records with levels and typed fields, spans, a
`std.log` backend, and sinks, delivered at the call or through queues a drain task renders. This describes
the implementation in this repository; change it with the code.

## Scope

In: levels (`trace`, `debug`, `info`, `warn`, `err`), scopes as enum literals, a compile-time floor per
scope and a run-time level per logger; typed fields from an anonymous struct (integers, floats,
booleans, enums, errors, strings, optionals, aegis scalars, almanac's values, any type with `format`);
spans with W3C Trace Context's id shapes (a 128-bit trace id, a 64-bit span id); a `std.log` backend;
sinks for text (logfmt's shape), JSON Lines and a chronicle journal; delivery at the call or queued.

Out, by decision:

- Trace context propagation (`traceparent`) and OTLP export: no consumer yet; the ids already have
  their shapes, so each adds as a sink or a header without reshaping.
- Metrics: counters and histograms are an aggregation engine, not records.
- Sampling and rate limiting: levels and scopes filter.
- Rotation by size or time: chronicle is the family's rotated log; a JSON Lines file sink reopens its
  path after an external rotation.
- Querying logs: chronicle's indexes and probe.

## Records

**A callsite is made once, at compile time.** Each `log.info(io, "message", fields)` instantiates a
static `Site`: level, scope, message, field names and kinds, and an encoder generated for the field
struct's type. A record is the site's pointer, a wall-clock timestamp, the span ids and the field values
packed into a small binary form; strings and `format` output are copied in, cut past `max_record` (16
KiB) and marked as cut. Nothing is formatted to text at the call when queued, and a record is encoded once
however many sinks render it. A record below its scope's floor is not compiled; the floors are std's own
(`std_options.log_level`, `log_scope_levels`), with std's `debug` admitting `trace`.

**Clocks.** `Record.at` is the wall clock as almanac's `Timestamp`. A span's duration is measured on the
monotonic clock, so a wall-clock step never makes it wrong or negative.

**No thread-local context.** A span or a producer is a value passed where it is used. Under an evented
`Io` a task resumes on any thread, so a thread-local current span would be wrong there.

## Delivery

`.sync` renders a record to each sink at the call, each sink behind its own lock through the call's
`Io`. `.queued` copies the encoded record into a bounded queue and returns; `drain(io)`, run by the
program with `io.concurrent`, renders queued records to the sinks.

- **The shared queue** is a ring under a lock taken through the `Io`, with a condition the drain waits on
  when it is empty and a producer when it is full. A full queue blocks the caller (cancelable) or drops the
  record, by option; drops are counted and written as a record of their own when there is room, so a gap
  says so.
- **A producer's own ring** (`logger.producer`) is single-producer and lock-free; the task that made it
  logs through it and passes it where it goes. The drain merges the rings and the shared queue by
  timestamp each turn, so each producer's order is kept.
- **When no drain runs**, before `drain` starts and after it returns, a queued call renders at the call:
  the drain publishes its state in an atomic every queued call reads, so a call never waits for a drain
  that is not coming and nothing is stranded at exit. A call that finds no drain renders what the queues
  still hold first, then its own record, so nothing comes out of order.
- **Sinks are flushed after each batch:** after a drain turn that rendered anything, after a record
  rendered at the call, and by `Logger.flush`. The chronicle sink appends a turn's records in one batch,
  one sync for the turn.

A log call never fails: a sink's failure is counted in `status()` with its first error, written as a record
to the other sinks, and the sink is tried again at the next record. A log call protects its write from
cancellation, so a canceled task never leaves half a line; `drain` is canceled at its waits and renders
what was queued before it returns.

## Modules

`blackbox` depends on aegis and almanac alone, so the toolchain may log through it. `blackbox_jsonl`
(the JSON Lines sink, over strand) and `blackbox_chronicle` (the chronicle sink) are always declared over
lazy dependencies, so the build takes no options: strand and chronicle are fetched with blackbox, and
compiled only into a program that imports a sink. The `std.log` backend is reached
through one atomic pointer the program sets with `install`; before it, a record goes to std's default
log and is counted.

## Safety

The field encoder refuses, at compile time, aegis's `Secret(T)` and `SecretBytes` and any type holding
them, naming the field's path: a secret reaches a log only through `declassify`. Strings are written
escaped, so a field cannot forge a line. Ids are `aegis.id.NonZero`, drawn from the `Io`'s random source (zero, which Trace Context reserves, is drawn again). A
span ended twice is `aegis.assert.invariant` in every build. `blackbox.lint_rules` replaces
`std.log.defaultLog` with blackbox's `logFn` in a program that imports it.

## Proof

Under shakedown's simulation, every schedule to a bound, and under real threads: every record is rendered
exactly once per sink or counted as dropped, in each task's order, with the drain stopping anywhere, and
none stranded or reordered when it stops beside a call. The encoder round trips every field kind and cuts
texts to prefixes at any limit; whatever bytes a field holds, the text and JSON Lines sinks write one line,
and strand reads the JSON back with numbers and texts as written. The chronicle sink appends a turn as one
batch and counts a journal's refusal.
