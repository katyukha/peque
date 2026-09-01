# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- **`peque:orm`** — compile-time ORM: model registry, schema generation,
  QuerySets and CRUD. `select!DTO` projects into a flat struct whose members are
  columns on the queried table; `@field(related: "partner.name")` projects a
  value reached through a relation, sharing its `LEFT JOIN` with
  `where`/`orderBy`/`load!`. Relation paths and the field names in
  `@uniqueTogether` / `@indexTogether` / `@uniqueIndexTogether` are validated at
  compile time. **Experimental** — the API may break on a minor version bump.
- **`peque:migrate`** — file-based migration runner with rollback and opt-in
  checksum pinning. **Experimental**, on the same terms.
- **Struct hydration** in the core package, usable without `peque:orm`:
  `ResultRow.as!T` / `Result.as!(T[])`, with a documented dispatch chain (user
  constructor, `fromRow` factory, `@model` strict mapping, annotated-fields
  mapping, `@autoHydrate` convention mapping). Column names come from one
  resolver shared by DDL, CRUD, QuerySet and hydration: `camelToSnake` of the D
  member name with runs of capitals kept whole (`myURL` is `my_url`), or
  `@field("col")` for an exact name. Table names are never derived — `@model`
  always takes the name, so renaming a struct cannot rename a table.
- **`timezone` on `Connection`** — pins the session `TimeZone` at connect via
  `set_config()`, so an unknown zone fails the connection. It is its own
  argument on every constructor rather than a key in the libpq `string[string]`
  map, and `makeVibePool` / `connectViaEnvParams` forward it. It governs only
  what the *server* renders; values peque sends and reads are
  session-independent regardless.

  **Breaking**: `timezone` precedes `ws`, so a `WaitStrategy` passed as the
  sixth positional argument must now be named — `ws: myStrategy`.
- **`groupByRaw!("name", "SQL expr")`** on `QuerySet` / `GroupedQuerySet` — an
  expression as a GROUP BY key, emitted into both `GROUP BY` and the SELECT
  list, which `annotate!` alone cannot do. Embedded verbatim, so trusted
  literals only. `groupBy!` now also works on `GroupedQuerySet`, so column and
  expression keys compose in either order.
- **`select!DTO` rejects a partly-annotated DTO** — without `@autoHydrate` the
  unannotated members were SELECTed and then left at `.init`. Now a compile
  error: annotate every member, or add `@autoHydrate`.
- **`@pgType` may not contradict the D type about time zones** —
  `@pgType("TIMESTAMPTZ") DateTime` and the like are now a `static assert`. The
  cast would run in the session `TimeZone`, storing a server-dependent instant.

### Changed

- **Temporal conversions no longer guess a time zone** (breaking). One rule
  covers all of them: peque returns what the value contains, possibly less, but
  never more. `timestamp` → `Date` still drops the time, while `timestamptz` →
  `DateTime`/`Date` and `timestamp` → `SysTime` now throw `ConversionError`
  naming the fix. Each was previously a silently different answer per server.
  The check follows the value's rendering rather than its OID, so array elements
  are covered too.
- **Every `SysTime` is returned in UTC.** The attached zone used to follow two
  rules, so two rows of one result set could print in different zones. Render
  with `.toLocalTime()` / `.toOtherTZ(tz)`; instants and comparisons are
  unaffected.
- **Exception tree redesigned** (breaking). Everything peque throws derives from
  `PequeException`, so a single `catch` covers the library. New types:
  `QueryClientError` and `QueryServerError` under `QueryError`; `IntegrityError`
  (SQLSTATE class 23, with an `IntegrityKind`) and `SerializationError`
  (class 40) under that; `NotSupportedError`; `LibpqLoadError`; and
  `ResultError` grouping `RowNotExistsError` and `ColNotExistsError`.
  `QueryEscapingError` moved under `QueryClientError`.

  Reclassified: libpq transport failures (`PQsendQuery`, `PQflush`,
  `PQconsumeInput`, `poll()`) raise `ConnectionError` — the link is broken, not
  the statement. COPY TO/FROM STDOUT, nested `exists!()` and `waitNotifications`
  without a timed `WaitStrategy` raise `NotSupportedError`.

  Exceptions now carry structured fields rather than only a message:
  `QueryServerError` has `sqlstate`, the backend diagnostics and
  `isRetriable()`; `ConversionError` has the source and target types and the
  offending value; the result errors carry the index or name, the result size
  and the columns that were available.
- **A dynamic build that cannot load `libpq` throws `LibpqLoadError`** instead
  of tripping `assert(0)`, which halted with no message under `-release`. It is
  a sibling of `ConnectionError`, not a subclass: no connection can succeed in
  the process, so retrying is pointless.
- **Conversion failures no longer escape peque's hierarchy** (breaking).
  `std.conv.ConvException`, `core.time.TimeException`, `std.json.JSONException`
  and `std.uuid.UUIDParsingException` used to propagate out of value conversion,
  so `catch (PequeException)` missed malformed text for most of the type table.
  All are now translated to `ConversionError`, preserving the original message —
  including `get!byte` on an out-of-range value, previously
  `ConvOverflowException`.
- `ConversionError` now reports `sourceType`, `targetType` and the offending
  `value` at every throw site, in both directions.
- The exception types are now re-exported from `peque` and `peque.orm`;
  `catch (QueryError)` after `import peque;` was previously an undefined
  identifier.

### Fixed

- **BC dates and years past 9999 could be read but not written.** PostgreSQL
  rejects D's `-0001-06-15` (it counts BC from 1 and wants `0002-06-15 BC`) and
  reads the leading sign of `+12345-01-01` as the start of a UTC offset. The
  year is now rewritten on the way out for `Date`, `DateTime` and `SysTime`, so
  a value peque can read is one it can write.
- **`SysTime` values were written using the session's time zone, silently
  shifting the instant.** `SysTime.toString` omits the UTC offset for
  `LocalTime()` values — what `Clock.currTime` returns — so PostgreSQL received
  a naked wall clock and read it in the *session* `TimeZone`: a host in
  `Europe/Kyiv` writing to a session in `UTC` stored everything three hours in
  the future, with no error. Values are now normalised with `.toUTC` first.
- **`infinity` / `-infinity` timestamps crashed.** The parser sliced these
  8-9 byte values as if they were `YYYY-MM-DD` — an `ArraySliceError` in a debug
  build and a **segfault under `-release`**. They now map to the D type's
  `.max`/`.min`.
- **`BC` dates silently returned the wrong year** for `Date`, `DateTime` and
  naive `timestamp` → `SysTime`: the suffix was dropped, so `0044-03-15 BC` read
  back as year 44 instead of -43. All timestamp paths now map PostgreSQL's BC
  years to D's astronomical numbering (1 BC = year 0).
- **`timestamptz` values rendered in local mean time could not be read at all.**
  Timestamps predating a zone's adoption of standard time carry a UTC offset
  with *seconds* (`+02:02:04`), and with a negative offset year 1 is pushed into
  the `BC` era — both rejected by `std.datetime`'s parser. Writing `SysTime.init`
  to a column was enough to trigger it, as was any date before the 1880s.
- **Array elements decoded by string length.** They carry no type OID, and the
  zoned/naive choice was made by `length == 19`: a naive value with fractional
  seconds is longer, so it came back in the *client's* local time, and
  `infinity` is shorter, so it was rejected as "too short". The decision now
  follows the rendering.
- **`const` / `immutable` values could not be passed as query parameters.**
  `is(T == DateTime)` is false for `immutable(DateTime)`, so such a value
  matched no `convertToPG` overload at all. `Date`, `DateTime`, `SysTime`,
  `JSONValue`, `UUID` and `Nullable!T` now match through qualifiers.
- A year outside D's representable range (it stores a year in a `short`, while
  PostgreSQL reaches 294276) now reports that plainly instead of `Invalid
  format`. A malformed UTC offset such as `+0230` is rejected rather than
  silently read as `+02:00`.

### Documentation

- **Which name goes where** — peque takes the D field name wherever it names a
  model member, and a SQL name only where no D name exists. `Target.columns!`'s
  error suggests the D field and lists the available ones, mirroring the schema
  UDAs' message.
- **Fields named after D keywords** — `@field("version") int version_;`. The D
  side keeps the underscore everywhere; only the emitted SQL drops it.
- **Where a column default belongs** — a D field initialiser for compile-time
  constants, `applyDefaults()` for computed values, and `@pgDefault` for
  database-level declarations only. `@pgDefault` never affects what peque
  inserts, which was undocumented and led to `@pgDefault("now()")` silently
  storing `SysTime.init`.

---

## [0.2.0]

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
- **Correctly rounded float results** — float8/float4/NUMERIC result values
  are parsed by `peque.converter.decimal.parseExactFloat` (correct rounding,
  half to even, on every platform); `std.conv` could be off by the last ulp
  where `real` has no extra precision over `double` (e.g. AArch64 macOS).
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
