# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- **`timezone` on `Connection`** — pins the session `TimeZone` once at connect,
  via `set_config()`, so an unknown zone fails the connection. Every constructor
  takes it as its own argument (not a key in the `string[string]` map, which
  stays libpq's), and `makeVibePool` / `connectViaEnvParams` forward it:
  `Connection(params, "UTC")`, `Connection(dbname: …, timezone: "UTC")`,
  `makeVibePool(8, params, "UTC")`. It governs only what the *server* renders
  (`now()::text`, `to_char`); values peque sends and reads are
  session-independent regardless. Connect-time only, since a pooled connection
  keeps session state across borrows.

  **Breaking**: `timezone` precedes `ws`, so a `WaitStrategy` passed as the sixth
  positional argument must now be named — `ws: myStrategy`.

- **`select!DTO` rejects a partly-annotated DTO.** Without `@autoHydrate`, only
  the annotated members hydrate, so the rest were SELECTed and then silently left
  at `.init`. Now a compile error: annotate every member, or add `@autoHydrate`.

- **`@pgType` may no longer contradict the D type about time zones** — a
  `static assert` on `@pgType("TIMESTAMPTZ") DateTime` and the like. peque types
  a parameter from the D value and PostgreSQL casts it to the column's real type;
  when the two disagree about zones that cast runs in the session `TimeZone`, so
  the stored instant differs per server. Only checkable where `@pgType` states
  the type — a column created outside the ORM stays the caller's responsibility.

- **`groupByRaw!("name", "SQL expr")`** on `QuerySet` / `GroupedQuerySet` — an
  expression as a GROUP BY key, emitted into both `GROUP BY` and the SELECT list.
  A grouping that is a *function* of a column — `date_trunc('day', ts AT TIME
  ZONE 'Europe/Kyiv')`, `lower(email)` — had no ORM spelling before: `annotate!`
  projects only, which PostgreSQL rejects with "must appear in the GROUP BY
  clause". Embedded verbatim like `annotate!`, so a trusted literal only, with no
  bound parameters. `groupBy!` also works on `GroupedQuerySet` now, so column and
  expression keys compose in either order.

- **Struct hydration** in the core package, usable without `peque:orm`:
  `ResultRow.as!T` / `Result.as!(T[])` with a documented dispatch chain (user
  constructor, `fromRow` factory, `@model` strict mapping, annotated-fields
  mapping, `@autoHydrate` convention mapping).

  Column names come from one resolver shared by DDL, CRUD, QuerySet and
  hydration: `camelToSnake` of the D member name, with runs of capitals kept
  whole (`myURL` is `my_url`), or `@field("col")` for an exact name. Since every
  identifier is emitted quoted, an explicit name keeps its case, which is how a
  mixed-case legacy column is addressed. Table names are never derived — `@model`
  always takes the name, so renaming a struct cannot rename a table.

  `@model` marks a *table* — it is what `isModel` requires, so only such a
  struct can enter a `Registry` or back a `Repository`. A struct whose members
  merely carry `@field`/`@primaryKey` hydrates as well, so a projection or a
  `RETURNING` row gets the same strict, aliasable mapping without claiming a
  table it does not have.

- **`peque:orm`** — ORM layer providing a compile-time model registry, schema
  generation, QuerySets and CRUD. `select!DTO` projects into a flat struct whose
  members are columns on the queried table — `@field("col")` included;
  `@field(related: "partner.name")` projects a value reached through a relation,
  sharing its `LEFT JOIN` with `where`/`orderBy`/`load!`. Relation paths are
  validated against the model at compile time, as are the field names in
  `@uniqueTogether` / `@indexTogether` / `@uniqueIndexTogether`.

- **`peque:migrate`** — Minimal migration runner infrastructure.

### Changed

- **Every `SysTime` is now returned in UTC.** The attached zone used to follow
  two rules — the session's offset normally, UTC on the local-mean-time and BC
  paths — so two rows of one result set could print in different zones. UTC is
  the only rule expressible here: an LMT offset like `+02:02:04` is not a
  whole-minute `SimpleTimeZone`. Render with `.toLocalTime()` / `.toOtherTZ(tz)`;
  instants and comparisons are unaffected.

- **Temporal conversions no longer guess a time zone** (breaking). One rule now
  covers all of them: peque returns what the value contains, possibly less, but
  never more. `timestamp` → `Date` still drops the time, while `timestamptz` →
  `DateTime`/`Date` (discarding a zone) and `timestamp` → `SysTime` (inventing
  one) throw `ConversionError` naming the fix — read a `timestamptz` as
  `SysTime`, and give a `timestamp` its zone with `SysTime(dt, UTC())`. Each was
  previously a silently different answer per server: an offset for `DateTime`, a
  whole day for `Date` either side of midnight. The check follows the value's
  rendering rather than its OID, so array elements are covered too.

- **Exception tree redesigned** (breaking). Every exception peque throws now
  derives from `PequeException`, so a single `catch` covers the library.

  New types: `QueryClientError` (your call is wrong) and `QueryServerError`
  (PostgreSQL rejected it) under `QueryError`; `IntegrityError` (SQLSTATE class
  23, with an `IntegrityKind`) and `SerializationError` (class 40) under that;
  `NotSupportedError`; and `ResultError` grouping `RowNotExistsError` and
  `ColNotExistsError`. `QueryEscapingError` moved under `QueryClientError`.

  Reclassified: libpq transport failures (`PQsendQuery`, `PQflush`,
  `PQconsumeInput`, `poll()`) now raise `ConnectionError` — the link is broken,
  not the statement. COPY TO/FROM STDOUT, nested `exists!()` and
  `waitNotifications` without a timed `WaitStrategy` raise `NotSupportedError`.

  Exceptions now carry structured fields rather than only a message:
  `QueryServerError` has `sqlstate`, the backend diagnostics
  (`constraintName`, `columnName`, `tableName`, …) and `isRetriable()`;
  `ConversionError` has the source and target types and the offending value;
  the result errors carry the index or name, the result size, and the columns
  that were available.
- **Conversion failures no longer escape peque's hierarchy** (breaking).
  `std.conv.ConvException`, `core.time.TimeException`, `std.json.JSONException`
  and `std.uuid.UUIDParsingException` used to propagate out of value conversion
  for `int`, `Date`, `DateTime`, `SysTime`, `JSONValue` and `UUID` — so
  `catch (PequeException)` missed malformed text for most of the type table.
  All of them are now translated to `ConversionError`, preserving the original
  message. Notably, `get!byte` on an out-of-range value now raises
  `ConversionError` instead of `ConvOverflowException`.
- `ConversionError` now reports `sourceType`, `targetType` and the offending
  `value` at every throw site, in both directions.
- The exception types are now re-exported from `peque` and `peque.orm`;
  `catch (QueryError)` after `import peque;` was previously an undefined
  identifier.


### Fixed

- **BC dates and years past 9999 could be read but not written.** D's ISO output
  is not what PostgreSQL parses at either end: `-0001-06-15` is rejected (it
  counts BC from 1 and wants `0002-06-15 BC`), and the leading sign of
  `+12345-01-01` is read as the start of a UTC offset. The year is now rewritten
  on the way out for `Date`, `DateTime` and `SysTime`, so a value peque can read
  is one it can write.

- **`const` / `immutable` values could not be passed as query parameters.**
  `is(T == DateTime)` is false for `immutable(DateTime)`, so such a value matched
  no `convertToPG` overload at all. `Date`, `DateTime`, `SysTime`, `JSONValue`,
  `UUID` and `Nullable!T` now match through qualifiers, as the trait-based
  constraints always did.

- **`SysTime` values were written using the session's time zone, silently
  shifting the instant.** `SysTime.toString` omits the UTC offset for
  `LocalTime()` values — what `Clock.currTime` returns, i.e. what the documented
  `applyDefaults` pattern inserts — so PostgreSQL received a naked wall clock and
  read it in the *session* `TimeZone`: a host in `Europe/Kyiv` writing to a
  session in `UTC` stored everything three hours in the future, with no error.
  Values are now normalised with `.toUTC` before formatting, which loses nothing
  — `timestamptz` discards the input offset anyway.

- **Array elements decoded by string length.** They carry no type OID, and the
  zoned/naive choice was made by `length == 19`: a naive value with fractional
  seconds is longer, so it came back in the *client's* local time, and
  `infinity` is shorter, so it was rejected as "too short". The decision now
  follows the rendering.

- **`infinity` / `-infinity` timestamps crashed.** These are ordinary
  `timestamp`/`timestamptz`/`date` values but only 8-9 bytes long, and the
  parser sliced them as if they were `YYYY-MM-DD` — an `ArraySliceError` in a
  debug build (uncatchable, since it is an `Error`) and a **segfault under
  `-release`**. They now map to the D type's `.max`/`.min`.
- **`BC` dates silently returned the wrong year** for `Date`, `DateTime` and
  naive `timestamp` → `SysTime`: the suffix was dropped and the year kept its
  positive value, so `0044-03-15 BC` read back as year 44 instead of -43.
  PostgreSQL counts BC years from 1 and D uses astronomical numbering
  (1 BC = year 0); all timestamp paths now convert consistently.
- A year outside D's representable range (it stores a year in a `short`, while
  PostgreSQL reaches 294276) now reports that plainly instead of `Invalid
  format`. A malformed UTC offset such as `+0230` is rejected rather than
  silently read as `+02:00`.
- `timestamptz` values that PostgreSQL renders in **local mean time** could not
  be read back at all. Timestamps predating a zone's adoption of standard time
  carry a UTC offset with *seconds* (`+02:02:04`), and with a negative offset
  year 1 is pushed into the `BC` era — both rejected by `std.datetime`'s parser.
  Writing `SysTime.init` to a column was enough to trigger it, as was any date
  before the 1880s. Such values now parse correctly, with PostgreSQL's BC years
  mapped to astronomical numbering (1 BC = year 0).

### Documentation

- **Which name goes where** — one rule, now that the schema UDAs have moved:
  peque takes the D field name wherever it names a model member, and a SQL name
  only where no D name exists. `Target.columns!`'s error also suggests the D
  field and lists the available ones, mirroring the schema UDAs' message.
- **Fields named after D keywords** — `@field("version") int version_;`. The D
  side keeps the underscore everywhere; only the emitted SQL drops it.

- Documented **where a column default belongs**: a D field initialiser for
  compile-time constants, `applyDefaults()` for computed values, and
  `@pgDefault` for database-level declarations only. `@pgDefault` never affects
  what peque inserts — peque always names every column — which was previously
  undocumented and led to `@pgDefault("now()")` silently storing `SysTime.init`.

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
