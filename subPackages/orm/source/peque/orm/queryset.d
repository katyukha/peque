/** Lazy query builder for peque:orm.
  *
  * QuerySet!(M, Ctx) is a value type that accumulates WHERE filters, ORDER BY,
  * LIMIT, and OFFSET clauses.  Nothing is sent to the database until a terminal
  * method is called.  QuerySets are immutable by convention — every builder
  * method returns a new copy, so you can safely branch from a base query:
  *
  * ---
  * auto base    = repo.query().where("active = $1", true);
  * auto admins  = base.where("role = $1", "admin").all();
  * auto editors = base.where("role = $1", "editor").all();
  * ---
  *
  * WHERE clauses use local $1/$2/… numbering — they are renumbered
  * automatically when multiple .where() calls are combined:
  * ---
  * repo.query()
  *     .where("status = $1", "active")
  *     .where("score > $1", 100)
  *     .all();
  * // → SELECT … WHERE (status = $1) AND (score > $2)
  * ---
  *
  * Terminal methods:
  *  - all()     → M[]         — fetch all matching rows
  *  - first()   → Nullable!M  — fetch at most one row
  *  - count()   → long        — SELECT COUNT(*)
  *  - exists()  → bool        — SELECT 1 … LIMIT 1
  *  - delete_() → long        — DELETE, returns rows deleted
  **/
module peque.orm.queryset;

private import std.typecons: Nullable, nullable;
private import std.conv: to;
private import std.traits: hasUDA;

private import peque.model: model, defaultOrder;
private import peque.converter: PGValue, convertToPG;
private import peque.query_context: isQueryContext;
private import peque.orm.repository: isModel;
private import peque.orm.sql: buildSelectList, ormTableName;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Scan sql for $N tokens and add offset to each N.
private string _renumberParams(string sql, int offset) pure {
    if (offset == 0) return sql;
    string result;
    size_t i = 0;
    while (i < sql.length) {
        if (sql[i] == '$' && i + 1 < sql.length &&
                sql[i + 1] >= '1' && sql[i + 1] <= '9') {
            ++i;
            size_t start = i;
            while (i < sql.length && sql[i] >= '0' && sql[i] <= '9') ++i;
            result ~= "$" ~ to!string(to!int(sql[start .. i]) + offset);
        } else {
            result ~= sql[i++];
        }
    }
    return result;
}

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


// ---------------------------------------------------------------------------
// QuerySet
// ---------------------------------------------------------------------------

/** Lazy, composable query builder for model M.
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
struct QuerySet(M, Ctx)
if (isModel!M && isQueryContext!Ctx) {

    private static struct _Where {
        string    sql;
        PGValue[] params;
    }

    private Ctx*     _ctx;
    private _Where[] _wheres;
    private string   _orderByClause;
    private long     _limitVal  = -1;
    private long     _offsetVal = -1;

    // Public because D instantiates template bodies at the call site, which
    // may be outside peque.orm — package(peque.orm) would fail there.
    this(Ctx* ctx) { _ctx = ctx; }

    // -----------------------------------------------------------------------
    // Builder methods — each returns a copy, leaving this unchanged
    // -----------------------------------------------------------------------

    /** Add a WHERE filter.
      *
      * sqlFrag uses local $1/$2/… numbering — placeholders are renumbered
      * relative to prior .where() calls at SQL build time.
      *
      * Example:
      * ---
      * qs.where("status = $1 AND score > $2", "active", 100)
      * ---
      **/
    QuerySet where(T...)(string sqlFrag, T args) {
        PGValue[] pgParams;
        static foreach (i, _; T)
            pgParams ~= convertToPG(args[i]);
        auto qs = this;
        qs._wheres ~= _Where(sqlFrag, pgParams);
        return qs;
    }

    /** Override the ORDER BY clause.
      *
      * If never called, the model's @defaultOrder UDA is used (if present).
      * Pass "" to suppress all ordering.
      **/
    QuerySet orderBy(string clause) {
        auto qs = this;
        qs._orderByClause = clause;
        return qs;
    }

    /// Set a row limit.
    QuerySet limit(long n) {
        auto qs = this;
        qs._limitVal = n;
        return qs;
    }

    /// Set a row offset.
    QuerySet offset(long n) {
        auto qs = this;
        qs._offsetVal = n;
        return qs;
    }

    // -----------------------------------------------------------------------
    // Internal — accumulate renumbered WHERE SQL and flat PGValue[].
    // -----------------------------------------------------------------------

    private void _buildWhere(out string whereSQL, out PGValue[] params) {
        whereSQL = "";
        params   = [];
        if (_wheres.length == 0) return;
        whereSQL = " WHERE ";
        int offset = 0;
        foreach (i, ref w; _wheres) {
            if (i > 0) whereSQL ~= " AND ";
            whereSQL ~= "(" ~ _renumberParams(w.sql, offset) ~ ")";
            offset += cast(int)w.params.length;
            params ~= w.params;
        }
    }

    // -----------------------------------------------------------------------
    // Terminal methods
    // -----------------------------------------------------------------------

    /** Fetch all matching rows. **/
    M[] all() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "SELECT " ~ buildSelectList!M() ~
                     " FROM "  ~ ormTableName!M ~ whereSQL;

        if (_orderByClause.length)
            sql ~= " ORDER BY " ~ _orderByClause;
        else {
            enum _defOrder = _modelDefaultOrder!M;
            static if (_defOrder.length)
                sql ~= " ORDER BY " ~ _defOrder;
        }

        if (_limitVal  >= 0) sql ~= " LIMIT "  ~ to!string(_limitVal);
        if (_offsetVal >= 0) sql ~= " OFFSET " ~ to!string(_offsetVal);

        return _ctx.execParams(sql, params).as!(M[]);
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

        string sql = "SELECT COUNT(*) FROM " ~ ormTableName!M ~ whereSQL;
        return _ctx.execParams(sql, params).getValue!long(0, 0);
    }

    /** Return true if at least one matching row exists. **/
    bool exists() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "SELECT 1 FROM " ~ ormTableName!M ~ whereSQL ~ " LIMIT 1";
        return _ctx.execParams(sql, params).ntuples > 0;
    }

    /** Delete all matching rows and return the number of rows deleted. **/
    long delete_() {
        string   whereSQL;
        PGValue[] params;
        _buildWhere(whereSQL, params);

        string sql = "DELETE FROM " ~ ormTableName!M ~ whereSQL;
        return _ctx.execParams(sql, params).cmdTuples();
    }
}
