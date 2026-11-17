# Changelog

All notable changes to blackbox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Structured records: levels, scopes with compile-time floors and a run-time level, typed fields
  from an anonymous struct, secrets refused at compile time.
- `blackbox_jsonl`, the JSON Lines sink, behind the build option `-Djsonl` (off by default; with it,
  strand is fetched): `JsonlSink` writes a record as one JSON object in `slog`'s shape to a writer,
  or appends to a file that `reopen` opens again by its path after a rotation (`openFailure` says
  why an open failed; the records meanwhile fail and are counted). `blackbox.built_with.jsonl` says
  whether a build has it.
- The logger flushes every sink after each turn of the drain, after each record rendered at the
  call, and after a producer renders its own ring, so a sink may batch what one of those renders.
