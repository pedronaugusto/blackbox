# Changelog

All notable changes to blackbox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Structured records: levels, scopes with compile-time floors and a run-time level, typed fields
  from an anonymous struct, secrets refused at compile time.
- `blackbox_jsonl`, the JSON Lines sink, a module every build declares over strand, a lazy
  dependency compiled only where a program imports the sink: `JsonlSink` writes a record as one JSON object in `slog`'s shape to a writer,
  or appends to a file that `reopen` opens again by its path after a rotation (`openFailure` says
  why an open failed; the records meanwhile fail and are counted).
- `JsonlSink.Output` and `JsonlSink.Appended` are public, the types of its `output` field, which
  a caller can reach.
- `blackbox_chronicle`, the chronicle sink, declared the same way over chronicle and strand:
  `ChronicleSink` appends each record to a
  `chronicle.Journal(chronicle.Raw)` as the JSON Lines sink's object, the records of a turn of the
  drain in one `appendAll` (`Options.commit`, `.group` by default), a batch past
  `Options.batch_bytes` before the turn ends; `lostRecords` and `appendFailure` say what a failed
  append took. The build takes no options: a program chooses a sink by importing it.
- The logger flushes every sink after each turn of the drain, after each record rendered at the
  call, and after a producer renders its own ring, so a sink may batch what one of those renders.
