# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- **LISTEN/NOTIFY** support via `Connection.listen`/`unlisten`.
- **Connection pool** (`peque.pool`) — Connection pool implementation.
- **Prepared statements** — `Connection.prepare(name, sql)` registers a
  server-side prepared statement and returns a move-only `PreparedStatement`
  handle; its destructor issues `DEALLOCATE` automatically.
- **`Connection.execMulti`** — execute multiple `;`-separated statements in a
  single call, checking each result.
- **`escapeIdentifier`** — safe quoting of SQL identifiers (also used
  internally by `listen`/`unlisten`).
- **`UUID` support** — `std.uuid.UUID` values round-trip as PostgreSQL `uuid`.
- **`Nullable!U[]` array conversion** — 1-D arrays with `Nullable!U` elements
  now round-trip; SQL NULL elements decode to empty `Nullable`s.
- **`ResultRow.nfields`** — column count on a row (mirrors `Result.nfields`).
- **`peque:vibe`** — vibe.d fiber-aware integration.

### Fixed

- **`Connection.close()` under GC finalization** — `close()` on a
  never-connected or already-finalized handle is now a safe no-op instead of
  throwing `AssertError` (hit when a GC-owned `ConnectionPool` was finalized).
- **Float parameter precision** — float parameters are serialized with
  round-trip-exact significant digits (`%g`-style); fixed-point `%.20f` used
  to zero magnitudes below ~5e-21 and truncate small values. `real`
  parameters are formatted by an exact pure-D decimal engine
  (`peque.converter.decimal`) — full 36-digit precision where `real` is IEEE
  binary128 (AArch64), where Phobos's `%g` silently falls back to double
  precision.
- **Native parameter OIDs** — integer and float parameters are declared as
  `INT2`/`INT4`/`INT8`/`FLOAT4`/`FLOAT8` instead of `NUMERIC` (`ulong` and
  `real` stay `NUMERIC`), so indexed comparisons like `WHERE id = $1` use
  btree indexes again. Arrays inherit the native OIDs.
- **Release-mode safety guards** — the NUL-byte check on string parameters is
  now a runtime `enforce` (`ConversionError`) instead of an `assert` that
  vanished in `-release` builds.
- **Result conversion errors survive `-release`** — data-driven `assert(0)`s
  in `convertTextTypeToD` (bad boolean text, pg type unmappable to the
  requested date/JSON type) now throw `ConversionError` instead of being
  compiled out.
- **Wide-string result conversion** — text columns read into `wstring` /
  `dstring` are now transcoded instead of byte-cast (which yielded garbage).
- **Array NULL elements** — an unquoted `NULL` in an array is a SQL NULL:
  empty element in `Nullable!U[]`, `ConversionError` for non-nullable element
  types. A quoted `"NULL"` stays the literal string.
- **COPY no longer hangs the connection** — `COPY ... TO/FROM STDOUT/STDIN`
  is rejected with `QueryError` instead of spinning at 100% CPU; the
  connection stays usable.
- **Non-blocking protocol edge cases** — the `PQflush` retry loop now waits
  readable-or-writable and consumes input (write-only wait could deadlock),
  and multi-statement `exec` no longer blocks inside `PQgetResult` after the
  first statement.
- **`serverVersion` on PostgreSQL 10.x** — 10.5 was reported as 10.0.5
  (off-by-one in the two-/three-part format cutoff).
- **Float special values** — `NaN`, `Infinity`, and `-Infinity` now round-trip
  correctly through `execParams` and result deserialization.
- **`escapeString`** — empty string no longer panics; null bytes are now
  rejected with `QueryEscapingError` before reaching `PQescapeStringConn`.
- **Row column bounds check** — `row[intIndex]` with an out-of-range index now
  throws `ColNotExistsError`, matching the `row["name"]` overload; previously
  it read silently as NULL.

### Changed

- **Async-only query path** — Use postgresql async infrastructure under the hood.
- **JSON parameters are sent as `jsonb`** — `JSONValue` parameters are now
  declared with the `JSONB` OID instead of `JSON`.

---

## [0.1.0] - 2026-02-22

### Added

- **`Connection.transaction()`** — RAII transaction helper. Calls `BEGIN` before
  the delegate and, on success, commits or rolls back depending on the `OnSuccess`
  template parameter. On exception the transaction is always rolled back
  automatically.

- **`Transaction` struct** — restricted connection handle passed into the
  `Connection.transaction()` delegate. Exposes `exec`, `execParams`, and
  `escapeString` but hides `commit()` and `rollback()`, making accidental early
  transaction termination a compile-time error rather than a silent runtime bug.

- **`OnSuccess` enum** — template parameter on `Connection.transaction()`
  controlling what happens when the delegate returns normally.
  `OnSuccess.commit` (default) commits; `OnSuccess.rollback` rolls back — useful
  for dry-runs and test helpers that must not persist changes.

- **`Transaction.savepoint()`** — RAII savepoint support for partial rollbacks
  within an open transaction. On exception only the savepoint changes are rolled
  back; the enclosing transaction remains intact. Savepoints may be nested
  arbitrarily. The delegate receives the same `ref Transaction` as
  `Connection.transaction()`, so business logic functions work at any nesting
  depth without modification. `OnSuccess.rollback` is supported.

- **Nullable type support** — `value.get!(Nullable!T)` returns `Nullable!T.init`
  for NULL columns instead of throwing `ConversionError`. Works for all supported
  value types.

- **JSON / JSONB support** — PostgreSQL `json` and `jsonb` columns are
  deserialized as `string`.

- **`Transaction` and `OnSuccess` exported** from the top-level `peque` package.

### Fixed

- `ResultRow` and `ResultValue` copyability — ref-count increment on copy now
  works correctly; previously copying could lead to double-free.
- `errorMessage` borrow lifetime — fixed potential dangling reference.
- Date and `DateTime` conversion to PostgreSQL format — edge cases in formatting
  handled correctly.
- `PGValue` conversion — added overflow and null checks when converting D values
  to PostgreSQL parameter format.

### Changed

- `exec` and `execParams` both call `ensureQueryOk()` automatically and
  consistently. `ensureQueryOk()` remains public on `Result` for advanced use
  cases, but normal usage after `exec`/`execParams` no longer requires it.

### Infrastructure

- CI now tests against multiple PostgreSQL server versions.
- Added ARM architecture test coverage.
