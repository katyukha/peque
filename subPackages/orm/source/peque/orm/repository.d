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
  *  - insert(ref M)        → M          (uses RETURNING to get generated PK)
  *  - update(ref M)        → void
  *  - deleteById(id)       → void
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

    private enum _crudSelAllSQL  = "SELECT " ~ _crudSel ~ " FROM " ~ _crudTable;
    private enum _crudSelByIdSQL = "SELECT " ~ _crudSel ~ " FROM " ~ _crudTable ~
                                   " WHERE " ~ _crudPk ~ " = $1";
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

    /** Return all rows as M[], with optional ORDER BY.
      *
      * Order of precedence (first match wins):
      *  1. Host repository defines `enum string defaultOrder = "col ASC"`.
      *  2. Model M carries `@defaultOrder!("col")` UDA.
      *  3. Neither — no ORDER BY, undefined DB order.
      **/
    M[] findAll() {
        import std.traits: hasUDA;
        import peque.model: defaultOrder;

        // Compute ORDER BY clause entirely at compile time.
        // We inline the logic here because mixin template symbols are resolved
        // at the instantiation site, so module-level helpers from repository.d
        // would not be visible when the mixin is used in other modules.
        enum _order = () {
            // 1. Per-repo override: host struct has `enum string defaultOrder`
            static if (__traits(hasMember, typeof(this), "defaultOrder") &&
                       is(typeof(typeof(this).defaultOrder) == string))
                return " ORDER BY " ~ typeof(this).defaultOrder;
            // 2. Model-level @defaultOrder UDA
            else static if (hasUDA!(M, defaultOrder)) {
                static foreach (uda; __traits(getAttributes, M)) {{
                    static if (is(uda) && is(uda == defaultOrder!fields, fields...)) {
                        string result;
                        bool first = true;
                        static foreach (f; fields) {
                            if (!first) result ~= ", ";
                            result ~= f;
                            first = false;
                        }
                        return " ORDER BY " ~ result;
                    }
                }}
                return "";  // unreachable but satisfies return-type inference
            }
            // 3. No ordering
            else
                return "";
        }();

        return _ctx.exec(_crudSelAllSQL ~ _order).as!(M[]);
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
      * Uses INSERT ... RETURNING so the returned M has the generated PK and
      * any server-side defaults filled in.  The original `record` is not
      * modified.
      **/
    M insert(ref M record) {
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

        enum _nf = countNonPkFields!M();
        auto params = buildInsertParamsMany!M(records);
        string sql = "INSERT INTO " ~ _crudTable ~
                     " (" ~ buildInsertColList!M() ~ ") VALUES " ~
                     buildMultiRowPlaceholders(_nf, records.length) ~
                     " RETURNING " ~ _crudSel;
        return _ctx.execParams(sql, params).as!(M[]);
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
