/** Repository pattern for peque:orm.
  *
  * Provides:
  *  - isModel!M           — compile-time constraint (struct + @model UDA)
  *  - CRUDMixin!(M, Ctx)  — mixin template; inject into user-defined repo structs
  *  - Repository!(M, Ctx) — ready-made concrete struct for quick use
  *
  * The host struct must expose a `private Ctx* _ctx` field before the mixin.
  *
  * Example — extend with custom queries:
  * ---
  * struct PartnerRepo {
  *     private Connection* _ctx;
  *     mixin CRUDMixin!(Partner, Connection);
  *
  *     Partner[] findActive() {
  *         return _ctx.execParams(
  *             "SELECT " ~ buildSelectList!Partner() ~ " FROM res_partner WHERE active = $1",
  *             true).as!(Partner[]);
  *     }
  * }
  * ---
  *
  * Example — direct use:
  * ---
  * auto repo = Repository!(Partner, Connection)(&conn);
  * auto all  = repo.findAll();
  * auto one  = repo.findById(42);
  * ---
  **/
module peque.orm.repository;

private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.traits: hasUDA;

private import peque.model: model;
private import peque.result: Result;
private import peque.query_context: isQueryContext;
private import peque.orm.sql;


// ---------------------------------------------------------------------------
// isModel
// ---------------------------------------------------------------------------

/** True when M is a struct annotated with @model.
  *
  * Use as a template constraint on repository structs and mixin templates
  * to get a clear compile error for unannotated types.
  **/
template isModel(M) {
    enum bool isModel = is(M == struct) && hasUDA!(M, model);
}


// ---------------------------------------------------------------------------
// CRUDMixin
// ---------------------------------------------------------------------------

/** Mixin that injects standard CRUD operations into a repository struct.
  *
  * Requirements:
  *  - The host struct must have a `private Ctx* _ctx` field.
  *  - M must satisfy isModel!M.
  *  - Ctx must satisfy isQueryContext!Ctx.
  *
  * Generated methods:
  *  - findAll()            → M[]
  *  - findById(id)         → Nullable!M
  *  - existsById(id)       → bool        (SELECT 1 … LIMIT 1; lighter than findById)
  *  - insert(ref M)        → M           (uses RETURNING to get generated PK)
  *  - insertMany(M[])      → M[]         (single round-trip, all PKs assigned)
  *  - upsert(ref M)        → M           (INSERT or ON CONFLICT (pk) DO UPDATE)
  *  - upsert!("f")(ref M)  → M           (INSERT or ON CONFLICT (f) DO UPDATE)
  *  - update(ref M)        → void
  *  - deleteById(id)       → void
  *  - deleteByRec(M)       → void        (record-based; extracts PK internally)
  *  - deleteByRec(M[])     → long        (single IN-clause round-trip)
  **/
mixin template CRUDMixin(M, Ctx)
if (isModel!M && isQueryContext!Ctx) {
    import std.typecons: Nullable, nullable;
    import std.conv: to;
    import peque.orm.sql;

    // Compile-time SQL constants — computed once, stored as enum strings.
    private enum _crudTable = ormTableName!M;
    private enum _crudSel   = buildSelectList!M();
    private enum _crudPk    = ormPkColName!M();

    private enum _crudSelByIdSQL = "SELECT " ~ _crudSel ~ " FROM " ~ _crudTable ~
                                   " WHERE " ~ _crudPk ~ " = $1";
    private enum _crudExistsByIdSQL = "SELECT 1 FROM " ~ _crudTable ~
                                      " WHERE " ~ _crudPk ~ " = $1 LIMIT 1";
    private enum _crudInsSQL     = "INSERT INTO " ~ _crudTable ~
                                   " (" ~ buildInsertColList!M() ~ ")" ~
                                   " VALUES (" ~ buildInsertPlaceholders!M() ~ ")" ~
                                   " RETURNING " ~ _crudSel;
    private enum _crudUpdSQL     = "UPDATE " ~ _crudTable ~
                                   " SET " ~ buildUpdateSetClause!M() ~
                                   " WHERE " ~ _crudPk ~
                                   " = $" ~ to!string(countNonPkFields!M() + 1);
    private enum _crudDelSQL     = "DELETE FROM " ~ _crudTable ~
                                   " WHERE " ~ _crudPk ~ " = $1";
    // upsert-by-PK SQL: used when caller provides an explicit PK value.
    private enum _crudUpsertByPkSQL =
        "INSERT INTO " ~ _crudTable ~
        " (" ~ _crudPk ~ ", " ~ buildInsertColList!M() ~ ")" ~
        " VALUES (" ~ buildInsertPlaceholders!(M, true)() ~ ")" ~
        " ON CONFLICT (" ~ _crudPk ~ ") DO UPDATE SET " ~
        _buildExcludedSetClause!M() ~
        " RETURNING " ~ _crudSel;

    /** Return all rows as M[], with optional ORDER BY.
      *
      * Order of precedence (first match wins):
      *  1. Host repository defines `enum string defaultOrder = "col ASC"`.
      *  2. Model M carries `@defaultOrder!("col")` UDA.
      *  3. Neither — no ORDER BY, undefined DB order.
      **/
    M[] findAll() {
        // Delegate to the QuerySet so ordering goes through one shared resolver
        // (raw strings, F! field terms, and join paths all behave identically
        // here and in query()). Precedence:
        //  1. Per-repo override: host struct has `enum string defaultOrder`.
        //  2. Model-level @defaultOrder UDA (applied by QuerySet automatically).
        //  3. Neither — no ORDER BY, undefined DB order.
        static if (__traits(hasMember, typeof(this), "defaultOrder") &&
                   is(typeof(typeof(this).defaultOrder) == string))
            return query().orderBy(typeof(this).defaultOrder).all();
        else
            return query().all();
    }

    /** Return true if a row with the given primary-key value exists.
      *
      * Executes SELECT 1 … LIMIT 1 — fetches no column data, lighter than findById.
      **/
    bool existsById(PkType)(PkType id) {
        return _ctx.execParams(_crudExistsByIdSQL, id).ntuples > 0;
    }

    /** Return the row matching id, or Nullable.init if not found.
      *
      * PkType is inferred — pass an int, long, or whatever the PK column type is.
      **/
    Nullable!M findById(PkType)(PkType id) {
        auto r = _ctx.execParams(_crudSelByIdSQL, id);
        if (r.ntuples == 0) return Nullable!M.init;
        return r.getRow(0).as!M.nullable;
    }

    /** Insert record into the DB and return the inserted row.
      *
      * If M defines `void applyDefaults()`, it is called on `record` before
      * the INSERT so runtime-computed defaults (timestamps, tokens, …) are
      * applied.  Static field defaults (e.g. `bool active = true`) are
      * already carried by the struct and need no special handling.
      *
      * Uses INSERT ... RETURNING so the returned M has the generated PK and
      * any server-side defaults filled in.  The original `record` is not
      * modified by the RETURNING result, but `applyDefaults` mutates it
      * in place before sending.
      **/
    M insert(ref M record) {
        static if (__traits(hasMember, M, "applyDefaults"))
            record.applyDefaults();
        return mixin(
            `_ctx.execParams(_crudInsSQL, ` ~ buildInsertValueExpr!M() ~ `)`
        ).getRow(0).as!M;
    }

    /** Insert multiple records in a single statement and return the inserted rows.
      *
      * Uses INSERT … VALUES (…), (…) … RETURNING to fetch all generated PKs and
      * server-side defaults in one round-trip.  Returns [] immediately when
      * records is empty.  Order of returned rows matches insertion order.
      **/
    M[] insertMany(M[] records) {
        if (records.length == 0) return [];

        static if (__traits(hasMember, M, "applyDefaults"))
            foreach (ref r; records) r.applyDefaults();

        enum _nf = countNonPkFields!M();
        auto params = buildInsertParamsMany!M(records);
        string sql = "INSERT INTO " ~ _crudTable ~
                     " (" ~ buildInsertColList!M() ~ ") VALUES " ~
                     buildMultiRowPlaceholders(_nf, records.length) ~
                     " RETURNING " ~ _crudSel;
        return _ctx.execParams(sql, params).as!(M[]);
    }

    /** Insert or update by primary key.
      *
      * Behaviour depends on the PK field value at runtime:
      *  - PK == typeof(PK).init (e.g. int 0) → plain INSERT; DB assigns the PK.
      *  - PK is set              → INSERT … ON CONFLICT (pk) DO UPDATE SET
      *                             non_pk_cols=EXCLUDED.non_pk_cols RETURNING *.
      *
      * The returned M always reflects the final DB state (RETURNING *).
      *
      * Use this for idempotent re-saves of records with caller-provided PKs
      * (UUIDs, natural integer keys) or to re-apply a previously inserted record.
      * For natural-key upserts (conflict on email, code, …) use upsert!"field".
      **/
    M upsert(ref M record) {
        static assert(_buildExcludedSetClause!M().length > 0,
            M.stringof ~ " has no non-PK fields; upsert() has nothing to update. " ~
            "Use insert() instead.");
        enum _pkField = ormPkFieldName!M();
        auto pkVal = __traits(getMember, record, _pkField);
        if (pkVal == typeof(pkVal).init)
            return insert(record);
        return mixin(
            `_ctx.execParams(_crudUpsertByPkSQL, ` ~ buildInsertValueExpr!(M, true)() ~ `)`
        ).getRow(0).as!M;
    }

    /** Insert or update by a natural conflict key (or composite key).
      *
      * conflictFields: one or more D field names on M that carry a UNIQUE
      * constraint in the DB (e.g. upsert!"email" or upsert!("tenantId","code")).
      *
      * PK behaviour:
      *  - PK == init → INSERT without PK (DB auto-assigns).
      *  - PK is set  → INSERT with PK; on conflict the PK is not overwritten.
      *
      * DO UPDATE SET covers all non-PK, non-conflict-key columns.
      * The returned M reflects the final DB state (RETURNING *).
      **/
    M upsert(conflictFields...)(ref M record)
    if (conflictFields.length > 0) {
        // Compile-time validation
        static foreach (cf; conflictFields) {
            static assert(is(typeof(cf) == string),
                "upsert conflict fields must be string literals, got: " ~
                typeof(cf).stringof);
            static assert(_fieldColName!(M, cf)().length > 0,
                "'" ~ cf ~ "' is not a DB column field on " ~ M.stringof);
        }
        enum _setCl = _buildExcludedSetClause!(M, conflictFields)();
        static assert(_setCl.length > 0,
            "upsert!" ~ conflictFields.stringof ~ " on " ~ M.stringof ~
            " leaves no fields to update (all non-PK fields are conflict keys). " ~
            "Use insert() instead.");

        // Conflict column list  e.g. "email" or "tenant_id, code"
        enum _conflictCols = () {
            string r;
            static foreach (cf; conflictFields) {
                if (r.length) r ~= ", ";
                r ~= _fieldColName!(M, cf)();
            }
            return r;
        }();

        enum _pkField = ormPkFieldName!M();
        auto pkVal = __traits(getMember, record, _pkField);

        if (pkVal == typeof(pkVal).init) {
            // PK not set — exclude from INSERT, let DB assign
            enum _sql = "INSERT INTO " ~ _crudTable ~
                        " (" ~ buildInsertColList!M() ~ ")" ~
                        " VALUES (" ~ buildInsertPlaceholders!M() ~ ")" ~
                        " ON CONFLICT (" ~ _conflictCols ~ ") DO UPDATE SET " ~
                        _setCl ~
                        " RETURNING " ~ _crudSel;
            return mixin(
                `_ctx.execParams(_sql, ` ~ buildInsertValueExpr!M() ~ `)`
            ).getRow(0).as!M;
        } else {
            // PK set — include in INSERT; never overwrite existing PK on conflict
            enum _sqlPk = "INSERT INTO " ~ _crudTable ~
                          " (" ~ _crudPk ~ ", " ~ buildInsertColList!M() ~ ")" ~
                          " VALUES (" ~ buildInsertPlaceholders!(M, true)() ~ ")" ~
                          " ON CONFLICT (" ~ _conflictCols ~ ") DO UPDATE SET " ~
                          _setCl ~
                          " RETURNING " ~ _crudSel;
            return mixin(
                `_ctx.execParams(_sqlPk, ` ~ buildInsertValueExpr!(M, true)() ~ `)`
            ).getRow(0).as!M;
        }
    }

    /** Update the row matching record's PK with record's current field values.
      *
      * All non-PK column fields are written.  If you want a partial update,
      * write a custom method using execParams directly.
      **/
    void update(ref M record) {
        mixin(
            `_ctx.execParams(_crudUpdSQL, ` ~ buildUpdateValueExpr!M() ~ `);`
        );
    }

    /// Delete the row with the given primary-key value.
    void deleteById(PkType)(PkType id) {
        _ctx.execParams(_crudDelSQL, id);
    }

    /// Delete the row matching record's PK.
    void deleteByRec(M record) {
        enum _pkField = ormPkFieldName!M();
        deleteById(__traits(getMember, record, _pkField));
    }

    /** Delete all records in the slice and return the number of rows deleted.
      *
      * Uses a single DELETE … WHERE pk IN ($1, $2, …) round-trip.
      * Returns 0 immediately when records is empty.
      **/
    long deleteByRec(M[] records) {
        import peque.converter: PGValue, convertToPG;

        if (records.length == 0) return 0;

        enum _pkField = ormPkFieldName!M();
        PGValue[] pkParams;
        pkParams.reserve(records.length);
        foreach (ref r; records)
            pkParams ~= convertToPG(__traits(getMember, r, _pkField));

        string ph;
        foreach (i; 0 .. records.length) {
            if (i > 0) ph ~= ", ";
            ph ~= "$" ~ (i + 1).to!string;
        }

        string sql = "DELETE FROM " ~ _crudTable ~
                     " WHERE " ~ _crudPk ~ " IN (" ~ ph ~ ")";
        return _ctx.execParams(sql, pkParams).cmdTuples();
    }

    /** Return a fresh QuerySet for model M scoped to this context.
      *
      * Example:
      * ---
      * auto active = repo.query().where("active = $1", true).all();
      * auto count  = repo.query().count();
      * ---
      **/
    auto query() {
        import peque.orm.queryset: QuerySet;
        return QuerySet!(M, Ctx)(_ctx);
    }
}


// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/** Ready-made repository struct wrapping CRUDMixin.
  *
  * For simple cases where you only need standard CRUD and no custom methods,
  * use this directly.  For custom domain queries, define your own struct and
  * use `mixin CRUDMixin!(M, Ctx)` alongside them.
  *
  * Example:
  * ---
  * auto repo   = Repository!(Partner, Connection)(&conn);
  * auto all    = repo.findAll();
  * auto byId   = repo.findById(42);
  * auto newRow = repo.insert(Partner(0, "Acme", "acme@example.com"));
  * repo.update(newRow);
  * repo.deleteById(newRow.id);
  * ---
  **/
struct Repository(M, Ctx)
if (isModel!M && isQueryContext!Ctx) {
    private Ctx* _ctx;

    @disable this();

    this(Ctx* ctx) pure nothrow @nogc { _ctx = ctx; }

    mixin CRUDMixin!(M, Ctx);
}
