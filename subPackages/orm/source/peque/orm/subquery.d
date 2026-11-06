/** Single-column SQL subquery atom for peque:orm.
  *
  * SubQuery!T is produced by QuerySet.asSubquery!"field"() and consumed by
  * F!(M, "field").inSubquery(sub) or F!"field".inSubquery(sub).
  *
  * Example:
  * ---
  * // IDs of active categories
  * auto activeCatIds = catRepo.query()
  *     .where!"active"(true)
  *     .asSubquery!"id"();                           // SubQuery!int — no DB call
  *
  * // Products whose category is in that set
  * auto products = prodRepo.query()
  *     .where(F!(Product, "categoryId").inSubquery(activeCatIds))
  *     .all();
  *
  * // Products NOT in that set
  * auto rest = prodRepo.query()
  *     .where(~F!(Product, "categoryId").inSubquery(activeCatIds))
  *     .all();
  * ---
  **/
module peque.orm.subquery;

private import peque.converter: PGValue;


/** Single-column SQL subquery atom — carries SQL and bound parameters.
  *
  * T is the D type of the selected column, resolved at compile time by
  * asSubquery!"field"() from the model's field declaration.  It exists for
  * documentation and potential future compile-time type checking; PostgreSQL
  * enforces type compatibility at execution time.
  *
  * Only QuerySet.asSubquery!"field"() constructs one: the fields are package
  * so that a hand-built SELECT with several columns cannot reach the EXISTS
  * serialiser, which names a single column.
  **/
struct SubQuery(T) {
    package(peque.orm) string    sql;
    package(peque.orm) PGValue[] params;

    // A struct literal would initialise package fields from anywhere; a
    // constructor of its own closes that.
    package(peque.orm) this(string sql, PGValue[] params) {
        this.sql    = sql;
        this.params = params;
    }
}
