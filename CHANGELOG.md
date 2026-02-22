# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
