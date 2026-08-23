/** Repository pattern for peque:orm.
  *
  * Provides:
  *  - isModel!M           — compile-time constraint (struct + @model UDA)
  *  - CRUDMixin!(M, Ctx)  — mixin template; inject into user-defined repo structs
  *  - Repository!(M, Ctx) — ready-made concrete struct for quick use
  *
  * The host struct must expose a `private Ctx* _ctx` field before the mixin.
  *
  * LIFETIME: that is a bare pointer to a context the caller owns — typically a
  * Connection or Transaction living on the stack. The repository does not keep
  * the context alive, so it must not outlive what it points at, and the context
  * must not be moved while a repository refers to it. Build repositories where
  * you use them rather than storing them in long-lived structures.
  *
  * See CRUDMixin for a worked example of the host-struct pattern, and
  * Repository for the ready-made form.
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
    import peque.orm.conflict;
    import peque.orm.schema;

    // Compile-time SQL constants — computed once, stored as enum strings.
    /** PostgreSQL's extended-protocol Bind message carries an int16 parameter
      * count, so a single statement can bind at most 65535 values.
      *
      * The bulk helpers below check against it explicitly: exceeding it
      * otherwise surfaces as an opaque protocol error from libpq, far from the
      * call that caused it. Chunking is deliberately left to the caller — doing
      * it here would silently turn one statement into several and change the
      * atomicity of the operation for anyone not already inside a transaction.
      **/
    private enum size_t PG_MAX_BIND_PARAMS = 65535;

    private static void _checkBindParams(size_t nParams, size_t nRows,
                                         string what, size_t perRow) {
        // Local imports: CRUDMixin is mixed into the host struct, so lookup
        // happens in that module's scope rather than this one.
        import std.exception: enforce;
        import peque.exception: QueryClientError, QueryError;
        enforce!QueryClientError(nParams <= PG_MAX_BIND_PARAMS,
            what ~ " would bind " ~ to!string(nParams) ~ " parameters for " ~
            to!string(nRows) ~ " records, over PostgreSQL's limit of " ~
            to!string(PG_MAX_BIND_PARAMS) ~ " per statement. Split the input " ~
            "into batches of at most " ~
            to!string(perRow == 0 ? nRows : PG_MAX_BIND_PARAMS / perRow) ~
            " records (wrap them in a transaction if they must apply together).");
    }

    private enum _crudTable = ormTableName!M;
    private enum _crudSel   = buildSelectList!M();
    private enum _crudPk    = ormPkColName!M();

    private enum _crudSelByIdSQL = "SELECT " ~ _crudSel ~ " FROM " ~ _crudTable ~
                                   " WHERE " ~ _crudPk ~ " = $1";
    private enum _crudExistsByIdSQL = "SELECT 1 FROM " ~ _crudTable ~
                                      " WHERE " ~ _crudPk ~ " = $1 LIMIT 1";
    // A model whose only column is the primary key has an empty insert column
    // list; "INSERT INTO t () VALUES ()" is not valid SQL, so such tables use
    // the DEFAULT form instead. PK-only marker/identity tables are legitimate,
    // so this is handled rather than rejected.
    private enum _crudInsSQL     = countNonPkFields!M() == 0
        ? "INSERT INTO " ~ _crudTable ~ " (" ~ _crudPk ~ ") VALUES (DEFAULT)" ~
          " RETURNING " ~ _crudSel
        : "INSERT INTO " ~ _crudTable ~
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
    /** INSERT … ON CONFLICT … DO UPDATE, shared by every upsert form.
      *
      * withPk decides whether the primary key is part of the INSERT column
      * list: it is when the caller supplied one, and omitted when the database
      * should assign it. Called in enum context, so this is pure CTFE.
      **/
    private static string _upsertSQL(bool withPk)(string conflictCols, string setClause,
                                                 string indexPred = "") {
        return _insertHead!withPk() ~
               " ON CONFLICT (" ~ conflictCols ~ ")" ~
               (indexPred.length ? " WHERE " ~ indexPred : "") ~
               " DO UPDATE SET " ~ setClause ~
               " RETURNING " ~ _crudSel;
    }

    // INSERT INTO … VALUES … — the part every conflict form shares.
    private static string _insertHead(bool withPk)() {
        return "INSERT INTO " ~ _crudTable ~
               " (" ~ (withPk ? _crudPk ~ ", " : "") ~ buildInsertColList!M() ~ ")" ~
               " VALUES (" ~ buildInsertPlaceholders!(M, withPk)() ~ ")";
    }

    /** The `ON CONFLICT <target>` fragment for a conflict-target type.
      *
      * A partial unique index is only inferable when the statement repeats the
      * index predicate, so it is appended automatically when the target columns
      * match one — see _partialUniqueIndexPred.
      **/
    private static string _conflictTargetSQL(Tgt)() {
        static if (is(Tgt == TargetNone)) {
            return "";
        } else static if (is(Tgt == TargetConstraint!n, string n)) {
            return " ON CONSTRAINT " ~ _sqlIdent(Tgt._targetConstraint);
        } else {
            enum cols = _targetCols!Tgt();
            enum pred = _partialUniqueIndexPred!(M, cols);
            return " (" ~ _joinTargetCols!Tgt() ~ ")" ~
                   (pred.length ? " WHERE " ~ pred : "");
        }
    }

    // Resolved SQL column names for a TargetColumns!(...) target.
    private static string[] _targetCols(Tgt)() {
        string[] r;
        static foreach (f; Tgt._targetFields) {
            static assert(_fieldColName!(M, f)().length > 0,
                "'" ~ f ~ "' is not a DB column field on " ~ M.stringof ~
                ". Target.columns! takes D field names, not SQL column names.");
            r ~= _fieldColNameRaw!(M, f)();
        }
        return r;
    }

    private static string _joinTargetCols(Tgt)() {
        string r;
        static foreach (f; Tgt._targetFields) {
            if (r.length) r ~= ", ";
            r ~= _fieldColName!(M, f)();
        }
        return r;
    }

    // Conflict on the primary key — used when the caller provided a PK value.
    private enum _crudUpsertByPkSQL =
        _upsertSQL!true(_crudPk, _buildExcludedSetClause!M());

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

    /** INSERT … ON CONFLICT — the full spelling of the conflict forms.
      *
      * The action decides the return type:
      *  - `OnConflict.doNothing` → `Nullable!M`, empty when a conflicting row
      *    already existed and nothing was written.
      *  - `OnConflict.doUpdate`  → `M`, always the final row.
      *
      * The target says which conflicts count. `Target.columns!` takes D field
      * names; when they match a partial unique index (`@uniqueIndex(where:)`),
      * its predicate is emitted automatically, without which PostgreSQL cannot
      * infer the index at all.
      *
      * ---
      * repo.insert!(OnConflict.doNothing)(rec);                           // any conflict
      * repo.insert!(OnConflict.doNothing, Target.columns!("email"))(rec);
      * repo.insert!(OnConflict.doUpdate,  Target.columns!("email"))(rec);
      * ---
      *
      * As with insert(), `applyDefaults()` runs first and the PK is left out of
      * the INSERT so the database assigns it.
      **/
    auto insert(OnConflict action, Tgt = Target.none)(ref M record) {
        static assert(!(action == OnConflict.doUpdate && is(Tgt == TargetNone)),
            "insert!(OnConflict.doUpdate) needs a conflict target — PostgreSQL " ~
            "cannot know which columns to update without one. Use " ~
            "Target.columns!(\"field\") or Target.constraint!(\"name\").");

        static if (__traits(hasMember, M, "applyDefaults"))
            record.applyDefaults();

        enum _target = _conflictTargetSQL!Tgt();

        static if (action == OnConflict.doNothing) {
            enum _sql = _insertHead!false() ~ " ON CONFLICT" ~ _target ~
                        " DO NOTHING RETURNING " ~ _crudSel;
            auto res = mixin(
                `_ctx.execParams(_sql, ` ~ buildInsertValueExpr!M() ~ `)`
            );
            // No row means a conflicting row already existed. DO NOTHING is the
            // only form that can return nothing, which is why it alone is
            // Nullable!M.
            if (res.ntuples == 0) return Nullable!M.init;
            return res.getRow(0).as!M.nullable;
        } else {
            enum _setCl = _buildExcludedSetClauseForTarget!Tgt();
            static assert(_setCl.length > 0,
                "insert!(OnConflict.doUpdate, …) on " ~ M.stringof ~
                " leaves no columns to update — every non-PK column is part of " ~
                "the conflict target. Use insert!(OnConflict.doNothing, …).");
            enum _sql = _insertHead!false() ~ " ON CONFLICT" ~ _target ~
                        " DO UPDATE SET " ~ _setCl ~ " RETURNING " ~ _crudSel;
            return mixin(
                `_ctx.execParams(_sql, ` ~ buildInsertValueExpr!M() ~ `)`
            ).getRow(0).as!M;
        }
    }

    // EXCLUDED SET clause covering every non-PK column that is not part of the
    // conflict target — updating a target column is pointless and, for a
    // constraint target, we do not know which columns it covers.
    private static string _buildExcludedSetClauseForTarget(Tgt)() {
        static if (is(Tgt == TargetColumns!f, f...))
            return _buildExcludedSetClause!(M, Tgt._targetFields)();
        else
            return _buildExcludedSetClause!M();
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
        static if (_nf > 0)
            _checkBindParams(_nf * records.length, records.length,
                             "insertMany", _nf);
        static if (_nf == 0) {
            // PK-only model: no values to bind, one (DEFAULT) tuple per record.
            string rows;
            foreach (i; 0 .. records.length) {
                if (i) rows ~= ", ";
                rows ~= "(DEFAULT)";
            }
            string sql = "INSERT INTO " ~ _crudTable ~ " (" ~ _crudPk ~ ")" ~
                         " VALUES " ~ rows ~ " RETURNING " ~ _crudSel;
            return _ctx.exec(sql).as!(M[]);
        } else {
            auto params = buildInsertParamsMany!M(records);
            string sql = "INSERT INTO " ~ _crudTable ~
                         " (" ~ buildInsertColList!M() ~ ") VALUES " ~
                         buildMultiRowPlaceholders(_nf, records.length) ~
                         " RETURNING " ~ _crudSel;
            return _ctx.execParams(sql, params).as!(M[]);
        }
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
    M upsert()(ref M record) {
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

        // A partial unique index is only inferable when the statement repeats
        // its predicate, so @uniqueIndex(where:) columns carry it here too —
        // without this, upsert! on such a model could not run at all.
        enum _rawCols = () {
            string[] r;
            static foreach (cf; conflictFields) r ~= _fieldColNameRaw!(M, cf)();
            return r;
        }();
        enum _idxPred = _partialUniqueIndexPred!(M, _rawCols);

        enum _pkField = ormPkFieldName!M();
        auto pkVal = __traits(getMember, record, _pkField);

        if (pkVal == typeof(pkVal).init) {
            // PK not set — exclude from INSERT, let DB assign
            enum _sql = _upsertSQL!false(_conflictCols, _setCl, _idxPred);
            return mixin(
                `_ctx.execParams(_sql, ` ~ buildInsertValueExpr!M() ~ `)`
            ).getRow(0).as!M;
        } else {
            // PK set — include in INSERT; never overwrite existing PK on conflict
            enum _sqlPk = _upsertSQL!true(_conflictCols, _setCl, _idxPred);
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
    void update()(ref M record) {
        static assert(buildUpdateSetClause!M().length > 0,
            M.stringof ~ " has no non-PK column fields; update() would emit an " ~
            "empty SET clause. Nothing to update — the PK alone identifies the row.");
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
        _checkBindParams(records.length, records.length, "deleteByRec", 1);

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


/// The host-struct contract: a `private Ctx* _ctx` field before the mixin.
unittest {
    import peque.connection: Connection;
    import peque.model: model, field, primaryKey;

    static @model("doc_crud_partner") struct Partner {
        @primaryKey int    id;
        @field      string name;
        @field      bool   active;
    }

    // Extend the generated CRUD with your own queries.
    static struct PartnerRepo {
        private Connection* _ctx;
        mixin CRUDMixin!(Partner, Connection);

        Partner[] findActive() {
            return _ctx.execParams(
                "SELECT " ~ buildSelectList!Partner() ~
                " FROM doc_crud_partner WHERE active = $1",
                true).as!(Partner[]);
        }
    }
    static assert(is(PartnerRepo));
    static assert(__traits(hasMember, PartnerRepo, "findAll"));
    static assert(__traits(hasMember, PartnerRepo, "findActive"));

    // Or use the ready-made struct.
    static assert(is(Repository!(Partner, Connection)));

    // Omitting the _ctx field fails to compile — the mixin body references it
    // directly. Not asserted here: a mixin-template error escapes
    // __traits(compiles), so the check would fail the build rather than pass.
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
  *
  * // insert takes `ref M`, so the record must be an lvalue.
  * auto seed   = Partner(0, "Acme", "acme@example.com");
  * auto newRow = repo.insert(seed);
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
