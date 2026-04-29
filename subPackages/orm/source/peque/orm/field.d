/** Compile-time field reference builder for peque:orm WHERE predicates.
  *
  * Use the F template to build type-safe WHERE conditions. Field names and
  * column expressions are resolved at compile time via the model's UDA metadata.
  *
  * Basic usage:
  * ---
  * // equality — most common
  * repo.query().where(F!(User, "status")("active"))
  *
  * // comparison operators — .gt, .gte, .lt, .lte, .ne
  * repo.query().where(F!(User, "age").gte(18))
  * repo.query().where(F!(User, "score").ne(0))
  *
  * // LIKE
  * repo.query().where(F!(User, "name").like("%acme%"))
  *
  * // IN  (.contains avoids the 'in' keyword conflict)
  * repo.query().where(F!(User, "status").contains(["active", "pending"]))
  *
  * // IS NULL
  * repo.query().where(F!(User, "deletedAt").isNull)
  *
  * // OR / AND / NOT composition
  * repo.query().where(
  *     F!(User, "status")("active") | F!(User, "status")("pending")
  * )
  * repo.query().where(
  *     F!(User, "dept")("eng") & F!(User, "level").gte(3)
  * )
  * repo.query().where(~F!(User, "isAdmin")(false))
  * ---
  *
  * For a cleaner local syntax, define a model-specific alias:
  * ---
  * template UF(string f) { alias UF = F!(User, f); }
  * repo.query().where(UF!"status"("active") | UF!"status"("pending"))
  * ---
  *
  * For joined-model field conditions, see QuerySet.whereJoin!.
  **/
module peque.orm.field;

private import peque.converter: PGValue, convertToPG;
private import peque.orm.predicate;
private import peque.orm.sql: _fieldColName, ormTableName;


/** Compile-time field reference builder.
  *
  * colExpr is the resolved SQL expression (e.g. "_m.status_col").
  * All runtime data is in the Predicate nodes produced by the operator methods.
  **/
struct FieldBuilder(string colExpr) {
    /// Equality: F!(M, "field")(val)
    Predicate opCall(V)(V val) const {
        import peque.converter: convertToPG;
        return Predicate(EqNode(colExpr, convertToPG(val)));
    }

    /** Column-to-column equality: SF!(Inner, "fk")(F!(Outer, "pk"))
      *
      * Generates raw SQL `_sq.fk_col = _m.pk_col` with no bound parameters.
      * Used inside exists!() to correlate inner and outer tables.
      **/
    Predicate opCall(string otherExpr)(FieldBuilder!otherExpr) const {
        return Predicate(RawNode(colExpr ~ " = " ~ otherExpr, []));
    }

    /// Comparisons: .gt(v) > v, .gte(v) >= v, .lt(v) < v, .lte(v) <= v, .ne(v) != v
    Predicate gt(V)(V val)  const { return Predicate(OpNode(colExpr, ">",  convertToPG(val))); }
    /// ditto
    Predicate gte(V)(V val) const { return Predicate(OpNode(colExpr, ">=", convertToPG(val))); }
    /// ditto
    Predicate lt(V)(V val)  const { return Predicate(OpNode(colExpr, "<",  convertToPG(val))); }
    /// ditto
    Predicate lte(V)(V val) const { return Predicate(OpNode(colExpr, "<=", convertToPG(val))); }
    /// ditto
    Predicate ne(V)(V val)  const { return Predicate(OpNode(colExpr, "!=", convertToPG(val))); }

    /// LIKE: F!(M, "field").like("%pattern%")
    Predicate like(string pattern) const {
        import peque.converter: convertToPG;
        return Predicate(OpNode(colExpr, "LIKE", convertToPG(pattern)));
    }

    /** Set membership: F!(M, "field").contains(values)
      *
      * .contains() is used instead of .in() because 'in' is a D keyword.
      **/
    Predicate contains(V)(V[] vals) const {
        import peque.converter: convertToPG;
        assert(vals.length > 0, "contains() called with empty value list");
        PGValue[] pgVals;
        foreach (v; vals) pgVals ~= convertToPG(v);
        return Predicate(InNode(colExpr, pgVals));
    }

    /// IS NULL: F!(M, "field").isNull
    @property Predicate isNull() const {
        return Predicate(NullNode(colExpr));
    }
}


/** Build a compile-time field reference for model M, field fieldName.
  *
  * Column name is resolved via M's UDA metadata. Unknown field name or a
  * non-column field (e.g. @related, @one2many) is a compile-time error.
  *
  * The column expression uses "_m." prefix so it is unambiguous in both
  * plain and join queries (all QuerySet SQL paths alias the main table as _m).
  **/
template F(M, string fieldName) {
    private enum _col = _fieldColName!(M, fieldName)();
    static assert(_col.length > 0,
        "'" ~ fieldName ~ "' is not a DB column field on " ~ M.stringof ~
        " (must have @field, @primaryKey, or @many2one UDA)");
    enum FieldBuilder!("_m." ~ _col) F = FieldBuilder!("_m." ~ _col).init;
}


/** Build a compile-time field reference for the subquery table alias `_sq`.
  *
  * Used inside exists!() predicates to reference fields of the inner (subquery)
  * model. SF!(Invoice, "orderId") resolves to the `_sq.order_id` column expression.
  *
  * Typical usage:
  * ---
  * .where(
  *     exists!(Invoice)(
  *         SF!(Invoice, "orderId")(F!(Order, "id")) &  // _sq.order_id = _m.id
  *         SF!(Invoice, "status")("open")              // _sq.status = $1
  *     )
  * )
  * ---
  **/
template SF(M, string fieldName) {
    private enum _col = _fieldColName!(M, fieldName)();
    static assert(_col.length > 0,
        "'" ~ fieldName ~ "' is not a DB column field on " ~ M.stringof ~
        " (must have @field, @primaryKey, or @many2one UDA)");
    enum FieldBuilder!("_sq." ~ _col) SF = FieldBuilder!("_sq." ~ _col).init;
}


/** Build an EXISTS (SELECT 1 FROM table _sq WHERE (...)) predicate.
  *
  * M is the inner model; its @model table name is used as the subquery table.
  * inner is a Predicate built with SF!(M, fieldName) and/or F!(Outer, fieldName)
  * references correlating the subquery to the outer query.
  *
  * NOT EXISTS: ~exists!(M)(inner)  — uses the existing NotNode/~ operator.
  *
  * Note: single-level EXISTS only. Nested exists!() calls are not supported
  * because both inner tables would alias to `_sq`.
  *
  * ---
  * // Orders that have at least one open invoice
  * orderRepo.query()
  *     .where(
  *         exists!(Invoice)(
  *             SF!(Invoice, "orderId")(F!(Order, "id")) &
  *             SF!(Invoice, "status")("open")
  *         )
  *     )
  *     .all();
  *
  * // Orders with NO invoices at all
  * orderRepo.query()
  *     .where(~exists!(Invoice)(SF!(Invoice, "orderId")(F!(Order, "id"))))
  *     .all();
  * ---
  **/
Predicate exists(M)(Predicate inner) {
    enum tableName = ormTableName!M;
    return Predicate(ExistsNode(tableName, new Predicate(inner)));
}
