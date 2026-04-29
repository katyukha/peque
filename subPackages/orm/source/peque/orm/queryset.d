/** Lazy query builder for peque:orm.
  *
  * QuerySet!(M, Ctx, JoinFields...) is a value type that accumulates WHERE
  * filters, ORDER BY, LIMIT, OFFSET, SET (for partial updates), and join
  * specifications.  Nothing is sent to the database until a terminal method
  * is called.  QuerySets are immutable by convention — every builder method
  * returns a new copy, so you can safely branch from a base query:
  *
  * ---
  * auto base    = repo.query().where!"active"(true);
  * auto admins  = base.where!"role"("admin").all();
  * auto editors = base.where!"role"("editor").all();
  * ---
  *
  * Builder methods (return new QuerySet):
  *  - where!"field"(val)      — type-safe equality WHERE (compile-time field check)
  *  - whereIn!"field"(vals)   — type-safe IN clause
  *  - where(Predicate)        — composable predicate (F expressions, OR/AND/NOT)
  *  - whereRaw(sql, args...)  — raw SQL escape hatch (local $1/$2 renumbered)
  *  - orderBy(clause)         — set ORDER BY
  *  - limit(n)                — set LIMIT
  *  - offset(n)               — set OFFSET
  *  - set!(fieldName)(val)    — accumulate a SET assignment (for update())
  *  - joinOne!(relField)      — LEFT JOIN a @related/@many2one field
  *  - prefetch!(relField)     — schedule a post-query SELECT for @one2many/@many2many
  *
  * Terminal methods:
  *  - all()           → M[]         — fetch all matching rows
  *  - first()         → Nullable!M  — fetch at most one row
  *  - count()         → long        — SELECT COUNT(*)
  *  - exists()        → bool        — SELECT 1 … LIMIT 1
  *  - delete_()       → long        — DELETE, returns rows deleted
  *  - update()        → long        — partial UPDATE using accumulated set!() calls
  *  - select!DTO()    → DTO[]       — project main + join columns into a DTO
  **/
module peque.orm.queryset;

private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.traits: hasUDA, FieldNameTuple, Fields;

private import peque.model: model, defaultOrder, field, primaryKey, related,
    one2many, many2many, many2one, OnDelete, hasMany2OneUDA, autoHydrate;
private import peque.converter: PGValue, convertToPG;
private import peque.query_context: isQueryContext;
private import peque.orm.repository: isModel;
private import peque.orm.sql;
private import peque.orm.predicate;
private import peque.orm.field: FieldBuilder, F;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Extract the ORDER BY clause from @defaultOrder UDA on M, or "".
private template _modelDefaultOrder(M) {
    static if (hasUDA!(M, defaultOrder)) {
        private static string _compute() {
            static foreach (uda; __traits(getAttributes, M)) {{
                static if (is(uda) && is(uda == defaultOrder!fields, fields...)) {
                    string r;
                    static foreach (f; fields) {
                        if (r.length) r ~= ", ";
                        r ~= f;
                    }
                    return r;
                }
            }}
            return "";
        }
        enum string _modelDefaultOrder = _compute();
    } else {
        enum string _modelDefaultOrder = "";
    }
}

// Extract the inner (non-Nullable) type from a @related field on M named jf.
private template _innerRelType(M, string jf) {
    alias _FT = typeof(__traits(getMember, M, jf));
    static if (is(_FT == Nullable!U, U))
        alias _innerRelType = U;
    else
        alias _innerRelType = _FT;
}

// ---------------------------------------------------------------------------
// Module-level prefetch executor — called at runtime from a delegate stored
// in _prefetches.  Separate from QuerySet to avoid circular template issues.
// ---------------------------------------------------------------------------

private void _execPrefetch(M, Ctx, string relField)(ref M[] rows, Ctx* ctx) {
    import std.conv: to;
    import std.array: join;
    import peque.orm.sql: buildSelectList, ormTableName, ormPkColName,
        ormPkFieldName, _findM2OFKColFor;
    import peque.hydration: _hydrateAnnotated;

    static foreach (memberName; FieldNameTuple!M) {{
        static if (memberName == relField) {
            alias FieldType  = typeof(__traits(getMember, M, memberName));

            // ---- @one2many -----------------------------------------------
            static foreach (uda; __traits(getAttributes, __traits(getMember, M, memberName))) {{
                static if (is(uda) && is(uda == one2many!(TargetM, invField), TargetM, string invField)) {
                    // Collect PKs from main rows
                    alias PkType = typeof(__traits(getMember, M, ormPkFieldName!M()));
                    PkType[] pks;
                    foreach (ref r; rows) {
                        bool dup = false;
                        foreach (p; pks) if (p == __traits(getMember, r, ormPkFieldName!M())) { dup = true; break; }
                        if (!dup) pks ~= __traits(getMember, r, ormPkFieldName!M());
                    }
                    if (pks.length == 0) return;

                    // Build IN placeholders: $1, $2, ...
                    string placeholders;
                    foreach (i; 0 .. pks.length) {
                        if (i > 0) placeholders ~= ", ";
                        placeholders ~= "$" ~ to!string(i + 1);
                    }

                    // FK column on TargetM that references M
                    enum fkCol = _findM2OFKColFor!(TargetM, M)();
                    static assert(fkCol.length > 0,
                        "No @many2one!(" ~ M.stringof ~ ") field on " ~ TargetM.stringof);

                    string sql = "SELECT " ~ buildSelectList!TargetM() ~
                                 " FROM "  ~ ormTableName!TargetM ~
                                 " WHERE " ~ fkCol ~ " IN (" ~ placeholders ~ ")";

                    // Build PGValue[] array
                    PGValue[] pgParams;
                    foreach (pk; pks) pgParams ~= convertToPG(pk);

                    auto result = ctx.execParams(sql, pgParams);

                    // Stitch: for each target row, find matching M row(s)
                    TargetM[] targets;
                    targets.length = result.ntuples;
                    foreach (i; 0 .. result.ntuples)
                        targets[i] = result.getRow(i).as!TargetM;

                    enum invFkField = invField; // D field name on TargetM
                    foreach (ref m; rows) {
                        alias ElemType = typeof(FieldType.init[0]);
                        ElemType[] arr;
                        foreach (ref t; targets) {
                            if (__traits(getMember, t, invFkField) == __traits(getMember, m, ormPkFieldName!M()))
                                arr ~= t;
                        }
                        __traits(getMember, m, memberName) = arr;
                    }
                }
            }}

            // ---- @many2many ---------------------------------------------
            static foreach (uda; __traits(getAttributes, __traits(getMember, M, memberName))) {{
                static if (is(uda) && is(uda == many2many!(TargetM, jt, sk, tk), TargetM, string jt, string sk, string tk)) {
                    alias PkType = typeof(__traits(getMember, M, ormPkFieldName!M()));
                    PkType[] pks;
                    foreach (ref r; rows) {
                        bool dup = false;
                        foreach (p; pks) if (p == __traits(getMember, r, ormPkFieldName!M())) { dup = true; break; }
                        if (!dup) pks ~= __traits(getMember, r, ormPkFieldName!M());
                    }
                    if (pks.length == 0) return;

                    string placeholders;
                    foreach (i; 0 .. pks.length) {
                        if (i > 0) placeholders ~= ", ";
                        placeholders ~= "$" ~ to!string(i + 1);
                    }

                    enum targetPkCol = ormPkColName!TargetM();
                    string sql =
                        "SELECT " ~ buildSelectList!TargetM() ~ ", j." ~ sk ~
                        " FROM " ~ ormTableName!TargetM ~ " t" ~
                        " JOIN " ~ jt ~ " j ON j." ~ tk ~ " = t." ~ targetPkCol ~
                        " WHERE j." ~ sk ~ " IN (" ~ placeholders ~ ")";

                    PGValue[] pgParams;
                    foreach (pk; pks) pgParams ~= convertToPG(pk);

                    auto result = ctx.execParams(sql, pgParams);

                    // Decode target rows + selfKey column
                    // The self-key column is the last column appended to the query
                    foreach (ref m; rows) {
                        alias ElemType = typeof(FieldType.init[0]);
                        ElemType[] arr;
                        foreach (i; 0 .. result.ntuples) {
                            auto row = result.getRow(i);
                            auto selfKeyVal = row[sk].as!PkType;
                            if (selfKeyVal == __traits(getMember, m, ormPkFieldName!M())) {
                                arr ~= row.as!TargetM;
                            }
                        }
                        __traits(getMember, m, memberName) = arr;
                    }
                }
            }}
        }
    }}
}


private struct _QSSet {
    string  colName;
    PGValue value;
}


// ---------------------------------------------------------------------------
// QuerySet
// ---------------------------------------------------------------------------

/** Lazy, composable query builder for model M.
  *
  * JoinFields is a compile-time sequence of D field names (strings) that have
  * been added via .joinOne!(fieldName).  The type expands when joinOne! is
  * called, producing a new QuerySet type.
  *
  * Obtain one from a repository via .query():
  * ---
  * auto rows = repo.query()
  *                 .where("active = $1", true)
  *                 .orderBy("name ASC")
  *                 .limit(20)
  *                 .all();
  * ---
  **/
struct QuerySet(M, Ctx, JoinFields...)
if (isModel!M && isQueryContext!Ctx) {

    alias PrefetchFn = void delegate(ref M[], Ctx*);

    private Ctx*         _ctx;
    private Predicate[]  _wheres;
    private _QSSet[]     _sets;
    private string       _orderByClause;
    private long         _limitVal  = -1;
    private long         _offsetVal = -1;
    private PrefetchFn[] _prefetches;

    // Public because D instantiates template bodies at the call site, which
    // may be outside peque.orm — package(peque.orm) would fail there.
    this(Ctx* ctx) { _ctx = ctx; }

    // -----------------------------------------------------------------------
    // Builder methods — each returns a copy, leaving this unchanged
    // -----------------------------------------------------------------------

    /** Type-safe equality filter — field name validated at compile time.
      *
      * The column expression uses the "_m." table alias, which is always
      * present in the generated SQL (both plain and join paths).
      *
      * Example:
      * ---
      * repo.query().where!"active"(true).all()
      * repo.query().where!"status"("active").where!"score"(10).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) where(string fieldName, V)(V val) {
        return where(F!(M, fieldName)(val));
    }

    /** Type-safe IN filter — field name validated at compile time.
      *
      * Example:
      * ---
      * repo.query().whereIn!"status"(["active", "pending"]).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) whereIn(string fieldName, V)(V[] vals) {
        return where(F!(M, fieldName).contains(vals));
    }

    /** Composable predicate filter — supports OR, AND, NOT via F expressions.
      *
      * Example:
      * ---
      * repo.query().where(
      *     F!(Item, "status")("active") | F!(Item, "status")("pending")
      * ).all()
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) where(Predicate pred) {
        auto qs = this;
        qs._wheres ~= pred;
        return qs;
    }

    /** Raw SQL escape hatch — use when typed predicates don't cover the case
      * (date ranges, full-text search, subqueries, etc.).
      *
      * sqlFrag uses local $1/$2/… numbering — placeholders are renumbered
      * relative to prior filters at SQL build time.
      *
      * Example:
      * ---
      * qs.whereRaw("expires_at < $1", cutoff)
      * qs.whereRaw("tsv @@ to_tsquery($1)", query)
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) whereRaw(T...)(string sqlFrag, T args) {
        PGValue[] pgParams;
        static foreach (i, _; T)
            pgParams ~= convertToPG(args[i]);
        return where(Predicate(RawNode(sqlFrag, pgParams)));
    }

    /** Override the ORDER BY clause.
      *
      * If never called, the model's @defaultOrder UDA is used (if present).
      * Pass "" to suppress all ordering.
      **/
    QuerySet!(M, Ctx, JoinFields) orderBy(string clause) {
        auto qs = this;
        qs._orderByClause = clause;
        return qs;
    }

    /// Set a row limit.
    QuerySet!(M, Ctx, JoinFields) limit(long n) {
        auto qs = this;
        qs._limitVal = n;
        return qs;
    }

    /// Set a row offset.
    QuerySet!(M, Ctx, JoinFields) offset(long n) {
        auto qs = this;
        qs._offsetVal = n;
        return qs;
    }

    /** Accumulate a SET assignment for a partial / bulk UPDATE.
      *
      * fieldName must be a DB-column field on M (checked at compile time).
      * Call .update() after one or more .set!() calls to execute the UPDATE.
      *
      * Example:
      * ---
      * repo.query().where("id=$1", id).set!("name")("New name").update();
      * repo.query().where("active=$1", false).set!("active")(true).update();
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) set(string fieldName, V)(V value) {
        enum colName = _fieldColName!(M, fieldName)();
        static assert(colName.length > 0,
            "'" ~ fieldName ~ "' is not a DB column field on " ~ M.stringof);
        auto qs = this;
        qs._sets ~= _QSSet(colName, convertToPG(value));
        return qs;
    }

    /** Add a LEFT JOIN for a @related field backed by a @many2one FK.
      *
      * Returns a new QuerySet type with relField appended to JoinFields.
      *
      * Example:
      * ---
      * // Partner has @many2one!(Company) int companyId; and
      * //            @related Nullable!Company company;
      * repo.query().joinOne!("company").all();
      * ---
      **/
    auto joinOne(string relField)() {
        // Compile-time validation
        static assert(__traits(hasMember, M, relField),
            "'" ~ relField ~ "' is not a member of " ~ M.stringof);
        alias RelFieldDecl = __traits(getMember, M, relField);
        static assert(hasUDA!(RelFieldDecl, related),
            "'" ~ relField ~ "' on " ~ M.stringof ~ " does not have @related UDA");

        alias RelType = _innerRelType!(M, relField);
        enum fkCol = _fkColForRelatedField!(M, relField, RelType)();
        static assert(fkCol.length > 0,
            "No @many2one!(" ~ RelType.stringof ~ ") FK field found on " ~ M.stringof ~
            " for @related field '" ~ relField ~ "'." ~
            " If you have multiple FKs to the same type, add @related(\"fkFieldName\").");

        QuerySet!(M, Ctx, JoinFields, relField) qs2;
        qs2._ctx            = _ctx;
        qs2._wheres         = _wheres;
        qs2._sets           = _sets;
        qs2._orderByClause  = _orderByClause;
        qs2._limitVal       = _limitVal;
        qs2._offsetVal      = _offsetVal;
        qs2._prefetches     = _prefetches;
        return qs2;
    }

    /** Schedule a post-query prefetch for a @one2many or @many2many field.
      *
      * Returns the same QuerySet type (JoinFields unchanged).
      *
      * Example:
      * ---
      * partnerRepo.query().prefetch!("invoices").all();
      * partnerRepo.query().prefetch!("tags").all();
      * ---
      **/
    QuerySet!(M, Ctx, JoinFields) prefetch(string relField)() {
        alias RelFieldDecl = __traits(getMember, M, relField);

        // Validate: must have @one2many or @many2many
        enum bool _hasO2M = () {
            bool found = false;
            static foreach (uda; __traits(getAttributes, RelFieldDecl)) {{
                static if (is(uda) && is(uda == one2many!(T, inv), T, string inv))
                    found = true;
            }}
            return found;
        }();
        enum bool _hasM2M = () {
            bool found = false;
            static foreach (uda; __traits(getAttributes, RelFieldDecl)) {{
                static if (is(uda) && is(uda == many2many!(T, jt, sk, tk), T, string jt, string sk, string tk))
                    found = true;
            }}
            return found;
        }();
        static assert(_hasO2M || _hasM2M,
            "'" ~ relField ~ "' on " ~ M.stringof ~
            " does not have @one2many or @many2many UDA");

        auto qs = this;
        qs._prefetches ~= (ref M[] rows, Ctx* ctx) {
            _execPrefetch!(M, Ctx, relField)(rows, ctx);
        };
        return qs;
    }

    // -----------------------------------------------------------------------
    // Internal — accumulate renumbered WHERE SQL and flat PGValue[].
    // -----------------------------------------------------------------------

    private void _buildWhere(out string whereSQL, out PGValue[] params, int startOffset = 0) {
        whereSQL = "";
        params   = [];
        if (_wheres.length == 0) return;
        whereSQL = " WHERE ";
        int offset = startOffset;
        foreach (i, ref p; _wheres) {
            auto s = serializePredicate(p, offset);
            if (i > 0) whereSQL ~= " AND ";
            whereSQL ~= "(" ~ s.sql ~ ")";
            offset += cast(int)s.params.length;
            params ~= s.params;
        }
    }

    // -----------------------------------------------------------------------
    // Terminal methods
    // -----------------------------------------------------------------------

    /** Fetch all matching rows, applying any JoinFields LEFT JOINs and
      * any scheduled prefetches afterwards.
      **/
    M[] all() {
        import peque.hydration: _hydrateAnnotated;

        string    whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        static if (JoinFields.length == 0) {
            // Simple path — no joins
            string sql = "SELECT " ~ buildSelectList!M() ~
                         " FROM "  ~ ormTableName!M ~ " _m" ~ whereSQL;

            if (_orderByClause.length)
                sql ~= " ORDER BY " ~ _orderByClause;
            else {
                enum _defOrder = _modelDefaultOrder!M;
                static if (_defOrder.length)
                    sql ~= " ORDER BY " ~ _defOrder;
            }

            if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
            if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

            auto rows = _ctx.execParams(sql, params).as!(M[]);

            // Apply prefetches
            foreach (fn; _prefetches)
                fn(rows, _ctx);

            return rows;

        } else {
            // Join path — build SELECT with aliased main table + join extras
            enum _mainSel = _prefixedSelectList!(M, "_m")();

            // Build join extras at compile time for each JoinField
            string joinExtras;
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias  = "j" ~ to!string(idx);
                enum _prefix  = "__" ~ jf ~ "_";
                enum _extras  = _joinSelectExtras!(RelType, _jAlias, _prefix)();
                if (joinExtras.length) joinExtras ~= ", ";
                joinExtras ~= _extras;
            }}

            string sql = "SELECT " ~ _mainSel;
            if (joinExtras.length) sql ~= ", " ~ joinExtras;
            sql ~= " FROM " ~ ormTableName!M ~ " _m";

            // Append JOIN clauses
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias  = "j" ~ to!string(idx);
                enum _relTbl  = ormTableName!RelType;
                enum _relPk   = ormPkColName!RelType();
                enum _fkCol   = _fkColForRelatedField!(M, jf, RelType)();
                static assert(_fkCol.length > 0,
                    "No @many2one!(" ~ RelType.stringof ~ ") field found on " ~ M.stringof);
                sql ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _jAlias ~
                       " ON " ~ _jAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
            }}

            sql ~= whereSQL;

            if (_orderByClause.length)
                sql ~= " ORDER BY " ~ _orderByClause;
            else {
                enum _defOrder = _modelDefaultOrder!M;
                static if (_defOrder.length)
                    sql ~= " ORDER BY " ~ _defOrder;
            }

            if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
            if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

            auto result = _ctx.execParams(sql, params);

            M[] rows;
            rows.length = result.ntuples;
            foreach (ri; 0 .. result.ntuples) {
                auto row = result.getRow(ri);
                rows[ri] = _hydrateAnnotated!M(row);

                // Hydrate each joined relation
                static foreach (idx, jf; JoinFields) {{
                    alias RelType = _innerRelType!(M, jf);
                    enum _prefix   = "__" ~ jf ~ "_";
                    enum _pkPrefCol = _prefix ~ ormPkColName!RelType();
                    immutable pkIdx = row._fieldIndex(_pkPrefCol);
                    if (pkIdx >= 0 && !row[pkIdx].isNull) {
                        auto rel = _hydrateAnnotated!(RelType, _prefix)(row);
                        alias FT = typeof(__traits(getMember, rows[ri], jf));
                        static if (is(FT == Nullable!RelType))
                            __traits(getMember, rows[ri], jf) = rel.nullable;
                        else
                            __traits(getMember, rows[ri], jf) = rel;
                    }
                    // else: leave at init (Nullable.init or default)
                }}
            }

            // Apply prefetches
            foreach (fn; _prefetches)
                fn(rows, _ctx);

            return rows;
        }
    }

    /** Fetch the first matching row, or Nullable.init if none. **/
    Nullable!M first() {
        auto results = limit(1).all();
        if (results.length == 0) return Nullable!M.init;
        return results[0].nullable;
    }

    /** Return the number of matching rows (SELECT COUNT(*)). **/
    long count() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "SELECT COUNT(*) FROM " ~ ormTableName!M ~ " _m" ~ whereSQL;
        return _ctx.execParams(sql, params).getValue!long(0, 0);
    }

    /** Return true if at least one matching row exists. **/
    bool exists() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "SELECT 1 FROM " ~ ormTableName!M ~ " _m" ~ whereSQL ~ " LIMIT 1";
        return _ctx.execParams(sql, params).ntuples > 0;
    }

    /** Delete all matching rows and return the number of rows deleted. **/
    long delete_() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "DELETE FROM " ~ ormTableName!M ~ " _m" ~ whereSQL;
        return _ctx.execParams(sql, params).cmdTuples();
    }

    /** Execute a partial / bulk UPDATE using accumulated set!() assignments.
      *
      * Builds: UPDATE table SET col1=$1, col2=$2 WHERE (renumbered_where)
      * Set values are bound as $1..$N; WHERE params follow as $(N+1)..$(N+M).
      *
      * Returns the number of rows updated.
      *
      * Example:
      * ---
      * repo.query().where("id=$1", id).set!("name")("New").update();
      * ---
      **/
    long update() {
        assert(_sets.length > 0, "update() called with no set!() assignments");

        // Build SET clause: col1=$1, col2=$2, ...
        string setClause;
        PGValue[] setParams;
        foreach (i, ref s; _sets) {
            if (i > 0) setClause ~= ", ";
            setClause ~= s.colName ~ " = $" ~ to!string(i + 1);
            setParams ~= s.value;
        }

        // Build WHERE clause with params numbered after SET params
        string whereSQL;
        PGValue[] whereParams;
        _buildWhere(whereSQL, whereParams, cast(int)_sets.length);

        string sql = "UPDATE " ~ ormTableName!M ~ " _m" ~
                     " SET "   ~ setClause ~ whereSQL;

        PGValue[] allParams = setParams ~ whereParams;
        return _ctx.execParams(sql, allParams).cmdTuples();
    }

    /** Project matching rows into DTO[].
      *
      * For each field in DTO (hydrated via @autoHydrate convention):
      *  - camelToSnake(fieldName) is looked up first in the main-table columns,
      *    then in the join-column aliases (prefix "__jf_").
      *  - Main col with joins: "SELECT _m.col ..."
      *  - Join col:            "SELECT j0.col AS __jf_col ..."
      *
      * Example:
      * ---
      * @autoHydrate
      * struct PartnerDTO { int id; string name; string companyName; }
      * // With joinOne!("company"):
      * auto dtos = repo.query().joinOne!("company").select!PartnerDTO();
      * ---
      **/
    DTO[] select(DTO)() {
        import peque.hydration: camelToSnake, _hydrateAnnotated;

        // Build the SELECT list for DTO fields
        // Step 1: collect main-table col names
        string[string] mainCols;  // colName -> true (exists on main table)
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static if (_isColField!F)
                mainCols[_colName!(F, memberName)] = memberName;
        }}

        // Step 2: for each DTO field, determine source
        string selList;
        static foreach (i, dtoMemberName; FieldNameTuple!DTO) {{
            enum dtoColName = camelToSnake(dtoMemberName);

            // Check if it matches a main-table column
            bool isMain = (dtoColName in mainCols) !is null;

            if (selList.length) selList ~= ", ";

            static if (JoinFields.length == 0) {
                // No joins — just the col name directly
                selList ~= dtoColName;
            } else {
                if (isMain) {
                    selList ~= "_m." ~ dtoColName;
                } else {
                    // Check if it starts with any join field prefix
                    bool matched = false;
                    static foreach (idx, jf; JoinFields) {{
                        enum jfSnake = camelToSnake(jf);
                        enum jfPrefix = jfSnake ~ "_";
                        // The DTO col starts with jfPrefix?
                        if (!matched && dtoColName.length > jfPrefix.length &&
                            dtoColName[0 .. jfPrefix.length] == jfPrefix) {
                            // The remaining part is the join-table col name
                            enum _jAlias = "j" ~ to!string(idx);
                            string jColName = dtoColName[jfPrefix.length .. $];
                            selList ~= _jAlias ~ "." ~ jColName ~ " AS " ~ dtoColName;
                            matched = true;
                        }
                    }}
                    if (!matched) {
                        // Fallback: select as literal col name (may error at runtime)
                        selList ~= dtoColName;
                    }
                }
            }
        }}

        // Build FROM + JOINs
        string fromClause;
        static if (JoinFields.length == 0) {
            fromClause = " FROM " ~ ormTableName!M;
        } else {
            fromClause = " FROM " ~ ormTableName!M ~ " _m";
            static foreach (idx, jf; JoinFields) {{
                alias RelType = _innerRelType!(M, jf);
                enum _jAlias  = "j" ~ to!string(idx);
                enum _relTbl  = ormTableName!RelType;
                enum _relPk   = ormPkColName!RelType();
                enum _fkCol   = _fkColForRelatedField!(M, jf, RelType)();
                fromClause ~= " LEFT JOIN " ~ _relTbl ~ " " ~ _jAlias ~
                              " ON " ~ _jAlias ~ "." ~ _relPk ~ " = _m." ~ _fkCol;
            }}
        }

        string whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "SELECT " ~ selList ~ fromClause ~ whereSQL;

        if (_orderByClause.length)
            sql ~= " ORDER BY " ~ _orderByClause;
        else {
            enum _defOrder = _modelDefaultOrder!M;
            static if (_defOrder.length)
                sql ~= " ORDER BY " ~ _defOrder;
        }

        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        return _ctx.execParams(sql, params).as!(DTO[]);
    }
}
