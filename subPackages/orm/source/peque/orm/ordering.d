/** ORDER BY term representation for peque:orm.
  *
  * An `Ordering` is the normal form every ORDER BY input is reduced to before
  * SQL generation, so `@defaultOrder`, `QuerySet.orderBy`, and `select!DTO` all
  * resolve ordering through one code path.
  *
  * Three kinds (see `OrderKind`):
  *  - `raw`    — a verbatim SQL fragment (e.g. `"created_at DESC"`); emitted
  *               as-is, direction/NULLS ignored.  This is the escape hatch.
  *  - `column` — a resolved column expression (e.g. `"_m.created_at"`);
  *               direction and NULLS placement are appended.
  *  - `path`   — an unresolved model field path (e.g. `"partner.name"`);
  *               resolved to a column (adding LEFT JOINs as needed) at
  *               query-build time, then direction/NULLS appended.
  *
  * Construct via the `F` builders (`F!"field".desc`, `F!"partner.name"`), a raw
  * string, or the compile-time `QuerySet.orderBy!("-field")` form — rather than
  * populating the fields directly.
  **/
module peque.orm.ordering;

/// Sort direction for an ORDER BY term.
enum OrderDir : ubyte { asc, desc }

/// NULLS placement for an ORDER BY term (PostgreSQL).  `unspecified` lets the
/// server apply its default (NULLS LAST for ASC, NULLS FIRST for DESC).
enum OrderNulls : ubyte { unspecified, first, last }

/// How an `Ordering.expr` is interpreted.  See module docs.
package(peque.orm) enum OrderKind : ubyte { raw, column, path }

/// A single ORDER BY term.  See module docs for the meaning of each kind.
struct Ordering {
    package(peque.orm) OrderKind  kind = OrderKind.raw;
    package(peque.orm) string     expr;
    package(peque.orm) OrderDir   dir   = OrderDir.asc;
    package(peque.orm) OrderNulls nulls = OrderNulls.unspecified;

    /// Ascending (default).  No-op for `raw` terms.
    Ordering asc() const pure nothrow @safe        { return Ordering(kind, expr, OrderDir.asc,  nulls); }
    /// Descending.  No-op for `raw` terms.
    Ordering desc() const pure nothrow @safe       { return Ordering(kind, expr, OrderDir.desc, nulls); }
    /// Append `NULLS FIRST`.  No-op for `raw` terms.
    Ordering nullsFirst() const pure nothrow @safe { return Ordering(kind, expr, dir, OrderNulls.first); }
    /// Append `NULLS LAST`.  No-op for `raw` terms.
    Ordering nullsLast() const pure nothrow @safe  { return Ordering(kind, expr, dir, OrderNulls.last); }
}
