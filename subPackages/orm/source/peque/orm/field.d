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
  * For joined-model field conditions, use a relation path: F!"partner.name",
  * resolved by the QuerySet against the model at SQL-build time.
  **/
module peque.orm.field;

private import std.traits: isNumeric, isIntegral;
private import std.typecons: Nullable;

private import peque.converter: PGValue, convertToPG;
private import peque.exception: QueryEscapingError;
private import peque.orm.predicate;
private import peque.orm.subquery: SubQuery;
private import peque.orm.sql: _fieldColName, ormTableName;
private import peque.orm.ordering: Ordering, OrderKind;
private import peque.hydration: camelToSnake;


/// true if T is a FieldBuilder instantiation — used to keep the generic
/// value overloads (opCall/ne) from competing with the column-to-column ones.
private enum _isFieldBuilderType(T) = is(T == FieldBuilder!(e, FT), string e, FT);


// ---------------------------------------------------------------------------
// JsonFieldBuilder — returned by FieldBuilder.get("key")
// ---------------------------------------------------------------------------

private bool _isSafeJsonKey(string s) pure nothrow @safe @nogc {
    // '\'' breaks out of the SQL literal; '\\' does too when the server runs
    // with standard_conforming_strings = off; '\0' truncates the query string.
    foreach (c; s)
        if (c == '\'' || c == '\\' || c == '\0') return false;
    return true;
}

/** Predicate builder for a JSONB text-extracted value: `(col)->>'key'`.
  *
  * Produced by FieldBuilder.get("key") — do not construct directly.
  * key is embedded in the SQL expression; it should be a trusted, hardcoded
  * string. Keys containing a single quote, backslash or NUL are rejected
  * with QueryEscapingError.
  *
  * All comparison operators work on the extracted text value:
  * ---
  * repo.query().where(F!(Post, "meta").get("lang")("en"))
  * // → WHERE (_m.meta)->>'lang' = $1
  *
  * repo.query().where(F!(Post, "meta").get("score").gte("90"))
  * // → WHERE (_m.meta)->>'score' >= $1
  * ---
  **/
struct JsonFieldBuilder {
    private string _expr;   // e.g. "(_m.payload)->>'type'"

    this(string colExpr, string key) pure @safe {
        import std.exception: enforce;
        // The key is embedded in the SQL text, so this guard is the only
        // barrier against injection — enforce, not assert: it must survive
        // -release builds.
        enforce!QueryEscapingError(
            _isSafeJsonKey(key),
            "JSONB key must not contain single quotes, backslashes or NUL bytes: " ~ key);
        _expr = "(" ~ colExpr ~ ")->>'" ~ key ~ "'";
    }

    /// Equality: .get("key")("value")
    Predicate opCall(V)(V val) const {
        return Predicate(EqNode(_expr, convertToPG(val)));
    }

    /// Comparisons: .gt .gte .lt .lte .ne
    Predicate gt(V)(V val)  const { return Predicate(OpNode(_expr, ">",  convertToPG(val))); }
    /// ditto
    Predicate gte(V)(V val) const { return Predicate(OpNode(_expr, ">=", convertToPG(val))); }
    /// ditto
    Predicate lt(V)(V val)  const { return Predicate(OpNode(_expr, "<",  convertToPG(val))); }
    /// ditto
    Predicate lte(V)(V val) const { return Predicate(OpNode(_expr, "<=", convertToPG(val))); }
    /// ditto
    Predicate ne(V)(V val)  const { return Predicate(OpNode(_expr, "!=", convertToPG(val))); }

    /// LIKE pattern
    Predicate like(string pat)  const { return Predicate(OpNode(_expr, "LIKE",  convertToPG(pat))); }

    /// ILIKE (case-insensitive LIKE) pattern
    Predicate ilike(string pat) const { return Predicate(OpNode(_expr, "ILIKE", convertToPG(pat))); }

    /// IN (set membership): .get("key").contains(["a", "b"])
    Predicate contains(V)(V[] vals) const {
        if (vals.length == 0) return Predicate.none;
        PGValue[] pgVals;
        foreach (v; vals) pgVals ~= convertToPG(v);
        return Predicate(InNode(_expr, pgVals));
    }

    /// IS NULL
    @property Predicate isNull() const { return Predicate(NullNode(_expr)); }
}


/** Compile-time field reference builder.
  *
  * colExpr is the resolved SQL expression (e.g. "_m.status_col").
  * All runtime data is in the Predicate nodes produced by the operator methods.
  *
  * FieldT is the D type of the model field (set by the typed F!(M, "field")
  * form; void for the type-free F!"field" form).  It drives the result-type
  * inference of the aggregate builders (.sum/.avg/.min/.max/.count), which are
  * therefore only available on typed field references.
  **/
struct FieldBuilder(string colExpr, FieldT = void) {
    /// Equality: F!(M, "field")(val)
    Predicate opCall(V)(V val) const
    if (!_isFieldBuilderType!V) {
        import peque.converter: convertToPG;
        return Predicate(EqNode(colExpr, convertToPG(val)));
    }

    /** Column-to-column equality: SF!(Inner, "fk")(F!(Outer, "pk"))
      *
      * Generates raw SQL `_sq.fk_col = _m.pk_col` with no bound parameters.
      * Used inside exists!() to correlate inner and outer tables.
      **/
    Predicate opCall(string otherExpr, OFT)(FieldBuilder!(otherExpr, OFT)) const {
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
    Predicate ne(V)(V val)  const
    if (!_isFieldBuilderType!V) {
        return Predicate(OpNode(colExpr, "!=", convertToPG(val)));
    }

    /// LIKE: F!(M, "field").like("%pattern%")
    Predicate like(string pattern) const {
        import peque.converter: convertToPG;
        return Predicate(OpNode(colExpr, "LIKE", convertToPG(pattern)));
    }

    /// ILIKE (case-insensitive LIKE): F!(M, "field").ilike("%pattern%")
    Predicate ilike(string pattern) const {
        import peque.converter: convertToPG;
        return Predicate(OpNode(colExpr, "ILIKE", convertToPG(pattern)));
    }

    /** Set membership: F!(M, "field").contains(values)
      *
      * .contains() is used instead of .in() because 'in' is a D keyword.
      **/
    Predicate contains(V)(V[] vals) const {
        import peque.converter: convertToPG;
        if (vals.length == 0)
            return Predicate.none;
        PGValue[] pgVals;
        foreach (v; vals) pgVals ~= convertToPG(v);
        return Predicate(InNode(colExpr, pgVals));
    }

    /// IS NULL: F!(M, "field").isNull
    @property Predicate isNull() const {
        return Predicate(NullNode(colExpr));
    }

    /// Column-to-column !=: F!(M, "a").ne(F!(M, "b")) or F!"a".ne(F!"b")
    Predicate ne(string otherExpr, OFT)(FieldBuilder!(otherExpr, OFT)) const {
        return Predicate(RawNode(colExpr ~ " != " ~ otherExpr, []));
    }

    /** IN (SELECT ...): F!(M,"field").inSubquery(qs.asSubquery!"field"())
      *
      * sub is produced by QuerySet.asSubquery!"field"() — a SQL subquery atom
      * with no DB call.  NOT IN: ~F!(M, "field").inSubquery(sub).
      **/
    Predicate inSubquery(T)(SubQuery!T sub) const {
        return Predicate(InSubqueryNode(colExpr, sub.sql, sub.params));
    }

    /** JSONB text-extraction accessor: col->>'key'.
      *
      * Returns a JsonFieldBuilder whose operators generate `(col)->>'key' OP $N`
      * predicates.  Covers the common case of querying into a JSONValue field
      * by a known key (locale, attribute name, …).
      *
      * key is embedded directly in the SQL expression — pass only trusted,
      * hardcoded strings, never user input.
      *
      * Example:
      * ---
      * // WHERE (_m.name)->>'en' = $1
      * repo.query().where(F!(Product, "name").get("en")("Widget"))
      *
      * // WHERE (_m.meta)->>'score' >= $1
      * repo.query().where(F!(Post, "meta").get("score").gte("90"))
      * ---
      **/
    JsonFieldBuilder get(string key) const {
        return JsonFieldBuilder(colExpr, key);
    }

    /** ORDER BY term for this column.
      *
      * `F!"name"` (or `F!(M,"name")`) used directly in `orderBy()` sorts
      * ascending; `.desc` sorts descending.  Chain `.nullsFirst`/`.nullsLast`
      * on the result for explicit NULLS placement.
      * ---
      * repo.query().orderBy(F!"createdAt".desc, F!"name")
      * ---
      **/
    @property Ordering asc()  const { return Ordering(OrderKind.column, colExpr); }
    /// ditto
    @property Ordering desc() const { return Ordering(OrderKind.column, colExpr).desc; }

    // -----------------------------------------------------------------------
    // Aggregate builders — typed F!(M, "field") form only
    // -----------------------------------------------------------------------

    // The field's D type with Nullable stripped; void on type-free builders.
    static if (is(FieldT == Nullable!U, U))
        private alias _BaseT = U;
    else
        private alias _BaseT = FieldT;

    // The aggregate properties must be plain (non-template) properties: a
    // member-template property used in template-argument position — e.g.
    // aggregate!(F!(M, "amount").sum) — binds as a symbol instead of being
    // evaluated to a value.  Availability is therefore gated by
    // declaration-level static ifs: '.sum' on a string field or on the
    // type-free F!"field" form is "no such property" at compile time.
    static if (!is(FieldT == void)) {

        static if (isNumeric!_BaseT) {
            /** SUM(col) aggregate.
              *
              * Result type: long for integral fields, double for floating
              * fields.  Use in a scalar aggregate!() terminal, a HAVING
              * predicate, or orderBy():
              * ---
              * repo.query().aggregate!(F!(Invoice, "amount").sum)  // Nullable!double
              * .having(F!(Invoice, "amount").sum.gt(100.0))
              * .orderBy(F!(Invoice, "amount").sum.desc)
              * ---
              **/
            @property auto sum() const {
                static if (isIntegral!_BaseT)
                    return AggBuilder!("SUM(" ~ colExpr ~ ")", long).init;
                else
                    return AggBuilder!("SUM(" ~ colExpr ~ ")", double).init;
            }

            /** AVG(col) aggregate.  Result type is always double —
              * PostgreSQL returns NUMERIC text (e.g. "500.0000000000000000"),
              * which never parses as an integral type.
              **/
            @property auto avg() const {
                return AggBuilder!("AVG(" ~ colExpr ~ ")", double).init;
            }
        }

        /** MIN(col) aggregate.  Result type is the field's own D type, so it
          * also works for strings, dates and timestamps.
          **/
        @property auto min() const {
            return AggBuilder!("MIN(" ~ colExpr ~ ")", _BaseT).init;
        }

        /** MAX(col) aggregate.  Result type is the field's own D type. **/
        @property auto max() const {
            return AggBuilder!("MAX(" ~ colExpr ~ ")", _BaseT).init;
        }

        /** COUNT(col) aggregate — counts rows where col is not NULL.
          * Result type: long.  (For COUNT(*) use QuerySet.count().)
          **/
        @property auto count() const {
            return AggBuilder!("COUNT(" ~ colExpr ~ ")", long).init;
        }
    }
}


/** Compile-time aggregate expression builder — produced by the FieldBuilder
  * .sum/.avg/.min/.max/.count properties.  Zero runtime state.
  *
  *   sqlExpr — the aggregate SQL expression, e.g. "SUM(_m.amount)"
  *   DType   — the D result type (drives the aggregate!() terminal's
  *             Nullable!DType return type)
  *
  * Consumed by:
  *  - QuerySet.aggregate!(agg)          — scalar aggregate terminal
  *  - GroupedQuerySet.annotate!(name, agg) — grouped SELECT column
  *  - having(...) predicates via the comparison operators below
  *  - orderBy(...) via .asc/.desc
  **/
struct AggBuilder(string sqlExpr, DType) {
    /// The aggregate SQL expression — used verbatim by QuerySet SQL assembly.
    enum expr = sqlExpr;
    /// The D result type of the aggregate.
    alias ResultType = DType;

    /// Equality HAVING predicate: agg(val) → e.g. HAVING SUM(_m.amount) = $N
    Predicate opCall(V)(V val) const {
        return Predicate(EqNode(sqlExpr, convertToPG(val)));
    }

    /// Comparisons: .gt(v) > v, .gte(v) >= v, .lt(v) < v, .lte(v) <= v, .ne(v) != v
    Predicate gt(V)(V val)  const { return Predicate(OpNode(sqlExpr, ">",  convertToPG(val))); }
    /// ditto
    Predicate gte(V)(V val) const { return Predicate(OpNode(sqlExpr, ">=", convertToPG(val))); }
    /// ditto
    Predicate lt(V)(V val)  const { return Predicate(OpNode(sqlExpr, "<",  convertToPG(val))); }
    /// ditto
    Predicate lte(V)(V val) const { return Predicate(OpNode(sqlExpr, "<=", convertToPG(val))); }
    /// ditto
    Predicate ne(V)(V val)  const { return Predicate(OpNode(sqlExpr, "!=", convertToPG(val))); }

    /** ORDER BY term for this aggregate expression (emitted verbatim):
      * ---
      * .orderBy(F!(Invoice, "amount").sum.desc)   // ORDER BY SUM(_m.amount) DESC
      * ---
      **/
    @property Ordering asc()  const { return Ordering(OrderKind.column, sqlExpr); }
    /// ditto
    @property Ordering desc() const { return Ordering(OrderKind.column, sqlExpr).desc; }
}


/// true if T is an AggBuilder instantiation.
enum isAggBuilder(T) = is(T == AggBuilder!(e, D), string e, D);


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
    private alias _FT = typeof(__traits(getMember, M, fieldName));
    enum FieldBuilder!("_m." ~ _col, _FT) F = FieldBuilder!("_m." ~ _col, _FT).init;
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
    private alias _FT = typeof(__traits(getMember, M, fieldName));
    enum FieldBuilder!("_sq." ~ _col, _FT) SF = FieldBuilder!("_sq." ~ _col, _FT).init;
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


// ---------------------------------------------------------------------------
// Type-free F and SF — no explicit model type required
// ---------------------------------------------------------------------------

private bool _pathHasDot(string s) pure nothrow @safe @nogc {
    foreach (c; s) if (c == '.') return true;
    return false;
}

private size_t _pathDotCount(string s) pure nothrow @safe @nogc {
    size_t n = 0;
    foreach (c; s) if (c == '.') ++n;
    return n;
}

/** Type-free field builder — no explicit model type needed.
  *
  * For plain fields (no dot): resolves via camelToSnake convention, returns a
  * concrete FieldBuilder with "_m." prefix identical to F!(M, "field").
  *
  * For join paths (one or two dots): returns a PathBuilder that carries the
  * unresolved path. The QuerySet resolves it against the model at SQL-build time,
  * adding implicit LEFT JOINs as needed.
  *
  * Usage:
  * ---
  * repo.query().where(F!"status"("active"))          // plain field
  * repo.query().where(F!"partner.name"("Acme"))      // 1-level join, implicit JOIN
  * repo.query().where(F!"partner.company.rate"(5))   // 2-level join, implicit JOINs
  * repo.query().where(F!"invoiceId".ne(F!"orderId")) // column-to-column !=
  * repo.query().orderBy(F!"partner.name".asc)        // join path in ORDER BY
  * ---
  *
  * Note: plain-field resolution uses camelToSnake without model validation.
  * Typos in field names become runtime PostgreSQL errors rather than compile-time
  * failures. Use F!(M, "field") when compile-time validation is desired.
  **/
template F(string path) {
    static assert(_pathDotCount(path) <= 2,
        "F!\"" ~ path ~ "\": relation paths support at most two relation segments " ~
        "(\"rel.field\" or \"rel1.rel2.field\"). A deeper path cannot be resolved " ~
        "and would be emitted as a schema-qualified name, producing invalid SQL. " ~
        "Query from the far side of the relation instead.");
    static if (_pathHasDot(path)) {
        enum PathBuilder!path F = PathBuilder!path.init;
    } else {
        enum FieldBuilder!("_m." ~ camelToSnake(path)) F =
            FieldBuilder!("_m." ~ camelToSnake(path)).init;
    }
}

/** Type-free subquery field builder for use inside exists!() predicates.
  *
  * Returns a FieldBuilder with "_sq." prefix — no model type validation.
  * Column name resolved via camelToSnake convention.
  *
  * Usage (inside exists!(M)(...)  — M provides the inner table):
  * ---
  * exists!(Invoice)(
  *     SF!"orderId"(F!"id") &   // _sq.order_id = _m.id
  *     SF!"status"("open")      // _sq.status = $1
  * )
  * ---
  **/
template SF(string fieldName) {
    enum FieldBuilder!("_sq." ~ camelToSnake(fieldName)) SF =
        FieldBuilder!("_sq." ~ camelToSnake(fieldName)).init;
}


// ---------------------------------------------------------------------------
// PathBuilder — carries an unresolved field path for type-free F!
// ---------------------------------------------------------------------------

/** Unresolved join-path field builder produced by F!"rel.field".
  *
  * All operator methods produce PathNode predicates that the QuerySet resolves
  * against the model type at SQL-build time, adding implicit LEFT JOINs.
  *
  * Also produces ORDER BY terms via `.asc`/`.desc` for use in orderBy():
  *   .orderBy(F!"partner.name", F!"partner.rating".desc)
  **/
struct PathBuilder(string path) {
    /// Equality
    Predicate opCall(V)(V val) const {
        return Predicate(PathNode(path, "=", [convertToPG(val)], ""));
    }
    /// Column-to-column equality
    Predicate opCall(string other)(PathBuilder!other) const {
        return Predicate(PathNode(path, "=", [], other));
    }

    /// > v
    Predicate gt(V)(V val)  const { return Predicate(PathNode(path, ">",   [convertToPG(val)], "")); }
    /// >= v
    Predicate gte(V)(V val) const { return Predicate(PathNode(path, ">=",  [convertToPG(val)], "")); }
    /// < v
    Predicate lt(V)(V val)  const { return Predicate(PathNode(path, "<",   [convertToPG(val)], "")); }
    /// <= v
    Predicate lte(V)(V val) const { return Predicate(PathNode(path, "<=",  [convertToPG(val)], "")); }
    /// != v (scalar)
    Predicate ne(V)(V val)  const { return Predicate(PathNode(path, "!=",  [convertToPG(val)], "")); }
    /// Column-to-column !=
    Predicate ne(string other)(PathBuilder!other) const {
        return Predicate(PathNode(path, "!=", [], other));
    }

    /// LIKE pattern
    Predicate like(string pat) const {
        return Predicate(PathNode(path, "LIKE", [convertToPG(pat)], ""));
    }

    /// ILIKE (case-insensitive LIKE) pattern
    Predicate ilike(string pat) const {
        return Predicate(PathNode(path, "ILIKE", [convertToPG(pat)], ""));
    }

    /// IN (set membership)
    Predicate contains(V)(V[] vals) const {
        if (vals.length == 0)
            return Predicate.none;
        PGValue[] pgVals;
        foreach (v; vals) pgVals ~= convertToPG(v);
        return Predicate(PathNode(path, "IN", pgVals, ""));
    }

    /// IS NULL
    @property Predicate isNull() const {
        return Predicate(PathNode(path, "IS NULL", [], ""));
    }

    /** IN (SELECT ...): F!"rel.field".inSubquery(qs.asSubquery!"field"())
      *
      * The join path is resolved by the QuerySet at SQL-build time.
      * NOT IN: ~F!"rel.field".inSubquery(sub).
      **/
    Predicate inSubquery(T)(SubQuery!T sub) const {
        // op="IN_SUB", params=subquery params, otherPath=subquery SQL.
        // _resolvePred handles this case by constructing InSubqueryNode.
        return Predicate(PathNode(path, "IN_SUB", sub.params, sub.sql));
    }

    /** ORDER BY term for this join path.
      *
      * The path is resolved against the model (adding LEFT JOINs as needed) at
      * query-build time, then the direction is applied.
      * ---
      * repo.query().orderBy(F!"partner.name", F!"partner.rating".desc)
      * ---
      **/
    @property Ordering asc()  const { return Ordering(OrderKind.path, path); }
    /// ditto
    @property Ordering desc() const { return Ordering(OrderKind.path, path).desc; }
}

/** Normalize an order spec to an `Ordering`.
  *
  * Accepts a raw SQL `string` (→ verbatim term), an `F` builder
  * (`FieldBuilder`/`PathBuilder`, → ascending field term), or an existing
  * `Ordering` (returned unchanged).  Used by `QuerySet.orderBy` and the
  * `@defaultOrder` reader.
  **/
package(peque.orm) Ordering toOrdering(T)(T spec) {
    static if (is(T == Ordering))    return spec;
    else static if (is(T == string)) return Ordering(OrderKind.raw, spec);
    else                             return spec.asc;   // FieldBuilder / PathBuilder
}
