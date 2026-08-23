/** Compile-time SQL schema generation from peque:orm model definitions.
  *
  * Provides:
  *  - modelDDL!M()    — CREATE TABLE IF NOT EXISTS SQL for one model
  *  - schemaSQL!Reg() — CREATE TABLE SQL for every model in a Registry
  *
  * All functions are pure CTFE — call them in `enum` context or pass the result
  * to Connection.exec() at startup for zero-boilerplate schema bootstrap.
  *
  * Default D → PostgreSQL type mapping:
  *  bool                   → BOOLEAN
  *  byte/ubyte/short/ushort → SMALLINT
  *  int/uint               → INTEGER  (SERIAL when @primaryKey)
  *  long/ulong             → BIGINT   (BIGSERIAL when @primaryKey)
  *  float                  → REAL
  *  double                 → DOUBLE PRECISION
  *  string                 → TEXT
  *  Nullable!T             → PG type of T, without NOT NULL
  *
  * Override the default for a specific field with @pgType("..."):
  * ---
  * @pgType("VARCHAR(255)") string name;
  * @pgType("NUMERIC(10,2)") double price;
  * ---
  *
  * FK columns (@many2one) get REFERENCES automatically, with optional ON DELETE:
  * ---
  * @many2one!(Partner)                int   partnerId;
  * // → INTEGER NOT NULL REFERENCES res_partner(id)
  *
  * @many2one!(Partner, OnDelete.cascade) int  partnerId;
  * // → INTEGER NOT NULL REFERENCES res_partner(id) ON DELETE CASCADE
  *
  * @many2one!(Partner, OnDelete.setNull) Nullable!int editorId;
  * // → INTEGER REFERENCES res_partner(id) ON DELETE SET NULL
  * ---
  *
  * Column constraints:
  * ---
  * @unique          string email;     // UNIQUE
  * @check("x > 0") double price;     // CHECK (x > 0)
  * @pgDefault("0") int    stock;     // DEFAULT 0
  * @pgNotNull       Nullable!int qty; // NOT NULL (on an otherwise-nullable field)
  * ---
  *
  * Table constraints (applied on the model struct):
  * ---
  * @uniqueTogether!("name", "tenant_id")
  * @checkConstraint("chk_price", "price > 0")
  * @model("res_partner")
  * struct Partner { ... }
  * ---
  *
  * Index generation (appended after CREATE TABLE). The field must also be a
  * column — an index UDA on a non-column field is a compile error rather than a
  * silently missing index:
  * ---
  * @field @index                         string email;  // CREATE INDEX ON table (email)
  * @field @index(where: "active = true") string email;  // partial index
  * @field @uniqueIndex                   string slug;   // CREATE UNIQUE INDEX ON table (slug)
  * @field @pgType("TEXT[]") @ginIndex    string[] tags; // … USING gin (tags)
  * @field @gistIndex                     string loc;    // … USING gist (loc)
  * @field @hashIndex                     string code;   // … USING hash (code)
  *
  * @indexTogether!("partner_id", "status")
  * @model("sale_order")
  * struct Order { ... }         // CREATE INDEX ON sale_order (partner_id, status)
  *
  * @uniqueIndexTogether!("tenant_id", "email")
  * @model("users")
  * struct User { ... }          // CREATE UNIQUE INDEX ON users (tenant_id, email)
  * ---
  *
  * Two indexes deriving the same name are a compile-time error (every statement
  * carries IF NOT EXISTS, so the second would silently be a no-op). Disambiguate
  * with an explicit name::
  * ---
  * @field @index(where: "a = 1")
  *        @index(where: "b = 2", name: "idx_t_col_b") string col;
  * ---
  *
  * Index name convention (all checked against PostgreSQL's 63-byte limit at compile time):
  *   @index / @indexTogether        → idx_{table}_{col[s]}
  *   @uniqueIndex / @uniqueIndexTogether → uniq_{table}_{col[s]}
  *   @ginIndex                      → gin_{table}_{col}
  *   @gistIndex                     → gist_{table}_{col}
  *   @hashIndex                     → hash_{table}_{col}
  *
  * Statement order in schemaSQL equals the registry binding order — ensure
  * FK-referenced tables appear before the tables that reference them.
  **/
module peque.orm.schema;

private import std.traits: FieldNameTuple, hasUDA, getUDAs, TemplateOf;
private import std.typecons: Nullable;
private import std.json: JSONValue;
private import std.datetime: SysTime, DateTime, Date;
private import std.uuid: UUID;

private import peque.model:
    model, field, primaryKey, pgType,
    OnDelete, many2one, hasMany2OneUDA, many2oneUDAType,
    unique, check, pgDefault, pgNotNull,
    uniqueTogether, checkConstraint,
    index, uniqueIndex, ginIndex, gistIndex, hashIndex,
    indexTogether, uniqueIndexTogether;
private import peque.hydration: camelToSnake;
private import peque.orm.sql: _colInfos, ormTableName, ormTableNameRaw, ormPkColName,
    _isColField, _colName, _sqlIdent, _identSlug;
private import peque.orm.registry: Bind;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Map a D type to its default PostgreSQL base type string.
// Unwraps Nullable!T automatically.
private string _pgBaseType(T)() {
    static if (is(T == Nullable!U, U))
        return _pgBaseType!U();
    else static if (is(T == bool))
        return "BOOLEAN";
    else static if (is(T == byte) || is(T == ubyte) ||
                    is(T == short) || is(T == ushort))
        return "SMALLINT";
    else static if (is(T == int) || is(T == uint))
        return "INTEGER";
    else static if (is(T == long) || is(T == ulong))
        return "BIGINT";
    else static if (is(T == float))
        return "REAL";
    else static if (is(T == double))
        return "DOUBLE PRECISION";
    else static if (is(T == string))
        return "TEXT";
    else static if (is(T == JSONValue))
        return "JSONB";
    else static if (is(T == UUID))
        return "UUID";
    else static if (is(T == SysTime))
        return "TIMESTAMPTZ";
    else static if (is(T == DateTime))
        return "TIMESTAMP";
    else static if (is(T == Date))
        return "DATE";
    else
        static assert(false,
            "No default PostgreSQL type for D type `" ~ T.stringof ~
            "`. Annotate the field with @pgType(\"...\").");
}

private template _isNullable(T) {
    static if (is(T == Nullable!U, U))
        enum bool _isNullable = true;
    else
        enum bool _isNullable = false;
}

// Convert OnDelete enum to the SQL clause fragment (without "ON DELETE" prefix).
private string _onDeleteSQL(OnDelete od) pure {
    final switch (od) {
        case OnDelete.noAction:   return "";
        case OnDelete.restrict:   return "RESTRICT";
        case OnDelete.cascade:    return "CASCADE";
        case OnDelete.setNull:    return "SET NULL";
        case OnDelete.setDefault: return "SET DEFAULT";
    }
}

// Build one column definition:
//   col_name TYPE [NOT NULL|PRIMARY KEY] [DEFAULT expr] [UNIQUE] [CHECK (...)]
//            [REFERENCES ... [ON DELETE ...]]
private string _buildColDef(M, string memberName)() {
    alias F = __traits(getMember, M, memberName);
    alias FType = typeof(F);

    string colName = _sqlIdent(_colName!(F, memberName));

    // --- Determine type string ---
    string typeName;
    alias pgTypeUDAs = getUDAs!(F, pgType);
    static if (pgTypeUDAs.length > 0) {
        typeName = pgTypeUDAs[0].typeName;
    } else static if (hasUDA!(F, primaryKey)) {
        static if (is(FType == int) || is(FType == uint))
            typeName = "SERIAL";
        else static if (is(FType == long) || is(FType == ulong))
            typeName = "BIGSERIAL";
        else static if (is(FType == UUID))
            typeName = "UUID";
        else
            typeName = _pgBaseType!FType();
    } else {
        typeName = _pgBaseType!FType();
    }

    string result = colName ~ " " ~ typeName;

    // --- NOT NULL / PRIMARY KEY ---
    static if (hasUDA!(F, primaryKey)) {
        result ~= " PRIMARY KEY";
    } else static if (!_isNullable!FType) {
        result ~= " NOT NULL";
    } else static if (hasUDA!(F, pgNotNull)) {
        result ~= " NOT NULL";
    }

    // --- DEFAULT ---
    static if (hasUDA!(F, primaryKey) && is(FType == UUID) && !hasUDA!(F, pgDefault))
        result ~= " DEFAULT gen_random_uuid()";
    static foreach (uda; __traits(getAttributes, F)) {{
        static if (is(typeof(uda) == pgDefault))
            result ~= " DEFAULT " ~ uda.expr;
    }}

    // --- UNIQUE ---
    static if (hasUDA!(F, unique))
        result ~= " UNIQUE";

    // --- CHECK ---
    static foreach (uda; __traits(getAttributes, F)) {{
        static if (is(typeof(uda) == check))
            result ~= " CHECK (" ~ uda.expr ~ ")";
    }}

    // --- REFERENCES + ON DELETE ---
    static if (hasMany2OneUDA!F) {
        static foreach (uda; __traits(getAttributes, F)) {{
            static if (is(many2oneUDAType!uda == many2one!(T, od), T, OnDelete od)) {
                static if (od == OnDelete.setNull)
                    static assert(_isNullable!FType,
                        "@many2one with OnDelete.setNull requires Nullable field type on `"
                        ~ memberName ~ "`");
                result ~= " REFERENCES " ~ ormTableName!T ~ "(" ~ ormPkColName!T() ~ ")";
                static if (od != OnDelete.noAction)
                    result ~= " ON DELETE " ~ _onDeleteSQL(od);
            }
        }}
    }

    return result;
}

// Build the table-level constraint clauses for model M (UNIQUE, CHECK).
// ---------------------------------------------------------------------------
// Partial unique index lookup — used by ON CONFLICT inference
// ---------------------------------------------------------------------------

/** The WHERE predicate of a PARTIAL unique index on exactly `cols`, or "".
  *
  * PostgreSQL infers a conflict target from the inserted columns, and a partial
  * unique index only matches when the statement repeats its predicate:
  *
  *     CREATE UNIQUE INDEX ON t (slug) WHERE NOT deleted;
  *     INSERT … ON CONFLICT (slug) DO UPDATE …
  *       ERROR:  there is no unique or exclusion constraint matching the
  *               ON CONFLICT specification
  *     INSERT … ON CONFLICT (slug) WHERE NOT deleted DO UPDATE …   -- matches
  *
  * So a model declaring @uniqueIndex(where:) had an upsert that could not be
  * used at all. Finding the predicate here lets the ON CONFLICT clause carry it
  * automatically, with no extra API.
  *
  * Matching is set equality: index inference is order-insensitive.
  **/
// PUBLIC despite the underscore: CRUDMixin's body is compiled in the
// INSTANTIATING module's scope, so every symbol it touches must be reachable
// from outside peque.orm. The underscore still marks it as internal — not part
// of the API anyone should call directly.
template _partialUniqueIndexPred(M, string[] cols) {
    private static bool _sameSet(string[] a, string[] b) {
        if (a.length != b.length) return false;
        foreach (x; a) {
            bool found = false;
            foreach (y; b) if (x == y) { found = true; break; }
            if (!found) return false;
        }
        return true;
    }

    private static string _find() {
        // Field-level @uniqueIndex(where: "…") — a single-column index.
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static foreach (uda; __traits(getAttributes, F)) {{
                // Instance form only: the type form carries no predicate.
                static if (is(typeof(uda) == uniqueIndex)) {
                    if (uda.where.length &&
                        _sameSet(cols, [_colName!(F, memberName)]))
                        return uda.where;
                }
            }}
        }}
        // Model-level @uniqueIndexTogether!(…)(where: "…").
        static foreach (uda; __traits(getAttributes, M)) {{
            static if (!is(uda) && __traits(compiles, TemplateOf!(typeof(uda))) &&
                       __traits(isSame, TemplateOf!(typeof(uda)), uniqueIndexTogether)) {
                if (uda.where.length && _sameSet(cols, uda.columns))
                    return uda.where;
            }
        }}
        return "";
    }
    enum string _partialUniqueIndexPred = _find();
}

// Validate a model-level column list (@uniqueTogether / @indexTogether /
// @uniqueIndexTogether) against M's real columns, at compile time.
//
// These UDAs take SQL column names, not D member names — they sit beside raw
// `where:` clauses that must also be columns. That makes writing the member
// name the natural slip now that the two differ, and the emitted DDL is
// perfectly well-formed either way, so nothing complains until PostgreSQL runs
// it. Suggest the converted name when that is what happened.
private template _validateColList(M, string udaName, string[] cols) {
    private static string _knownCols() {
        string r;
        foreach (ci; _colInfos!M) { if (r.length) r ~= ", "; r ~= ci.col; }
        return r;
    }
    private static bool _isCol(string name) {
        foreach (ci; _colInfos!M) if (ci.col == name) return true;
        return false;
    }
    static foreach (col; cols) {
        static assert(_isCol(col),
            udaName ~ " on " ~ M.stringof ~ " names '" ~ col ~ "', which is not " ~
            "a column on it." ~
            (_isCol(camelToSnake(col)) ? " Did you mean '" ~ camelToSnake(col) ~
             "'? These UDAs take SQL column names, not D member names." : "") ~
            " Columns: " ~ _knownCols() ~ ".");
    }
    enum _validateColList = true;
}

private string _buildTableConstraints(M)() {
    string result;

    static foreach (uda; __traits(getAttributes, M)) {{
        // @uniqueTogether!("col1", "col2", ...)
        static if (is(uda) && __traits(isSame, TemplateOf!uda, uniqueTogether)) {
            static assert(_validateColList!(M, "@uniqueTogether", uda.columns));
            string cols;
            static foreach (col; uda.columns) {
                if (cols.length) cols ~= ", ";
                cols ~= _sqlIdent(col);
            }
            if (result.length) result ~= ",\n";
            result ~= "    UNIQUE (" ~ cols ~ ")";
        }
        // @checkConstraint("name", "expr")
        static if (is(typeof(uda) == checkConstraint)) {
            if (result.length) result ~= ",\n";
            result ~= "    CONSTRAINT " ~ _sqlIdent(uda.name) ~ " CHECK (" ~ uda.expr ~ ")";
        }
    }}

    return result;
}

// Join a string[] with "_" — used to build index names from column lists.
private string _joinUnderscore(string[] cols) pure {
    string r;
    foreach (i, c; cols) { if (i) r ~= "_"; r ~= _identSlug(c); }
    return r;
}

private enum size_t PG_MAX_IDENT = 63;

// Build one CREATE [UNIQUE] INDEX IF NOT EXISTS statement.
// enforce, not assert: modelDDL!M() is also callable at runtime (conn.exec(...)),
// where -release would strip an assert. Under CTFE this still fails the build.
// using_: access method; "btree" or "" → USING clause is omitted (btree is PG default).
private string _buildOneIndex(
    bool isUnique, string using_,
    string tbl, string cols, string where_, string idxName) pure
{
    import std.exception: enforce;
    enforce(idxName.length <= PG_MAX_IDENT,
        "Generated index name \"" ~ idxName ~ "\" exceeds PostgreSQL's " ~
        "63-byte identifier limit. Shorten the table or column name, or pass " ~
        "an explicit name: to the index UDA.");
    string s = "CREATE " ~ (isUnique ? "UNIQUE " : "") ~
               "INDEX IF NOT EXISTS " ~ idxName ~ " ON " ~ tbl;
    if (using_.length && using_ != "btree") s ~= " USING " ~ using_;
    s ~= " (" ~ cols ~ ")";
    if (where_.length) s ~= " WHERE " ~ where_;
    return s ~ ";\n";
}

// Emit one CREATE INDEX statement if `uda` matches UDAType (instance or type-value form).
// Instance form: @UDAType(where: "cond") → typeof(uda) == UDAType, reads uda.where.
// Type-value form: @UDAType (no parens)  → is(uda == UDAType),      where defaults to "".
// `table` and `col` arrive raw: the ON clause needs them quoted, while the
// generated index name must stay a bare identifier (idx_t_"order" is invalid).
private string _fieldIndexName(alias uda, UDAType,
                               string prefix, string table, string col)() {
    enum derived = prefix ~ _identSlug(table) ~ "_" ~ _identSlug(col);
    static if (is(typeof(uda) == UDAType))
        return uda.name.length ? uda.name : derived;
    else static if (is(uda == UDAType))
        return derived;
    else
        return "";
}

private string _tryBuildFieldIndex(alias uda, UDAType,
                                   bool isUnique, string using_, string prefix,
                                   string table, string col)() {
    static if (is(typeof(uda) == UDAType))
        return _buildOneIndex(isUnique, using_, _sqlIdent(table), _sqlIdent(col),
                              uda.where,
                              _fieldIndexName!(uda, UDAType, prefix, table, col)());
    else static if (is(uda == UDAType))
        return _buildOneIndex(isUnique, using_, _sqlIdent(table), _sqlIdent(col),
                              "",
                              _fieldIndexName!(uda, UDAType, prefix, table, col)());
    else
        return "";
}

// Emit one CREATE INDEX for a model-level @indexTogether / @uniqueIndexTogether,
// in either spelling. Mirrors _tryBuildFieldIndex: the type-value form
// (@UDAType!(cols)) carries no where/name, the instance form (@UDAType!(cols)(…))
// reads both. Returns "" when `uda` is not of that template.
private string _tryBuildTogetherIndex(M, alias uda, alias UDATemplate,
                                      bool isUnique, string prefix, string table)(
                                      out string idxName) {
    static if (is(uda) && __traits(isSame, TemplateOf!uda, UDATemplate)) {
        static assert(_validateColList!(M, "@" ~ __traits(identifier, UDATemplate),
                                        uda.columns));
        idxName = prefix ~ _identSlug(table) ~ "_" ~ _joinUnderscore(uda.columns);
        return _buildOneIndex(isUnique, "btree", _sqlIdent(table),
                              _joinQuoted(uda.columns), "", idxName);
    } else static if (!is(uda) && __traits(compiles, TemplateOf!(typeof(uda))) &&
                      __traits(isSame, TemplateOf!(typeof(uda)), UDATemplate)) {
        static assert(_validateColList!(M, "@" ~ __traits(identifier, UDATemplate),
                                        uda.columns));
        enum derived = prefix ~ _identSlug(table) ~ "_" ~ _joinUnderscore(uda.columns);
        idxName = uda.name.length ? uda.name : derived;
        return _buildOneIndex(isUnique, "btree", _sqlIdent(table),
                              _joinQuoted(uda.columns), uda.where, idxName);
    } else {
        idxName = "";
        return "";
    }
}

// Quote each column and join with ", " for an index column list.
private string _joinQuoted(string[] cols) pure {
    string r;
    foreach (i, c; cols) { if (i) r ~= ", "; r ~= _sqlIdent(c); }
    return r;
}

// True when `uda` is one of the field-level index UDAs, in either spelling.
private template _isFieldIndexUDA(alias uda) {
    private template _m(UDAType) {
        enum bool _m = is(typeof(uda) == UDAType) || is(uda == UDAType);
    }
    enum bool _isFieldIndexUDA =
        _m!index || _m!uniqueIndex || _m!ginIndex || _m!gistIndex || _m!hashIndex;
}

// Build all CREATE INDEX statements for model M.
// Handles field-level: @index, @uniqueIndex, @ginIndex, @gistIndex, @hashIndex
//          model-level: @indexTogether, @uniqueIndexTogether
// All support an optional WHERE clause for partial indexes and an explicit
// name: to disambiguate. Names are collected as they are generated so that
// collisions become a compile-time error instead of a silently skipped index
// (every statement carries IF NOT EXISTS, so a duplicate name is a no-op).
private string _buildIndexSQL(M)() {
    import std.exception: enforce;

    string   result;
    string[] names;
    enum table = ormTableNameRaw!M;

    // Field-level: for each UDA on a column field, try each known index type.
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            enum col = _colName!(F, memberName);
            static foreach (uda; __traits(getAttributes, F)) {{
                result ~= _tryBuildFieldIndex!(uda, index,       false, "btree", "idx_",  table, col)();
                names  ~= _fieldIndexName!(uda, index,       "idx_",  table, col)();
                result ~= _tryBuildFieldIndex!(uda, uniqueIndex, true,  "btree", "uniq_", table, col)();
                names  ~= _fieldIndexName!(uda, uniqueIndex, "uniq_", table, col)();
                result ~= _tryBuildFieldIndex!(uda, ginIndex,    false, "gin",   "gin_",  table, col)();
                names  ~= _fieldIndexName!(uda, ginIndex,    "gin_",  table, col)();
                result ~= _tryBuildFieldIndex!(uda, gistIndex,   false, "gist",  "gist_", table, col)();
                names  ~= _fieldIndexName!(uda, gistIndex,   "gist_", table, col)();
                result ~= _tryBuildFieldIndex!(uda, hashIndex,   false, "hash",  "hash_", table, col)();
                names  ~= _fieldIndexName!(uda, hashIndex,   "hash_", table, col)();
            }}
        } else {
            // An index UDA here used to be dropped without a word, so the schema
            // deployed "successfully" with the index missing.
            static foreach (uda; __traits(getAttributes, F)) {{
                static assert(!_isFieldIndexUDA!uda,
                    "Index UDA on `" ~ M.stringof ~ "." ~ memberName ~ "` has no " ~
                    "effect: only column fields can be indexed. Add @field (or " ~
                    "@primaryKey / @many2one) to make it a column.");
            }}
        }
    }}

    // Model-level: @indexTogether and @uniqueIndexTogether, either spelling.
    static foreach (uda; __traits(getAttributes, M)) {{
        string _n;
        result ~= _tryBuildTogetherIndex!(M, uda, indexTogether, false, "idx_", table)(_n);
        names  ~= _n;
        result ~= _tryBuildTogetherIndex!(M, uda, uniqueIndexTogether, true, "uniq_", table)(_n);
        names  ~= _n;
    }}

    foreach (i, a; names) {
        if (!a.length) continue;
        foreach (b; names[i + 1 .. $])
            enforce(a != b,
                "Two indexes on " ~ M.stringof ~ " both generate the name \"" ~ a ~
                "\". Every CREATE INDEX carries IF NOT EXISTS, so the second would " ~
                "be silently skipped. Disambiguate with an explicit name:, e.g. " ~
                "@index(where: \"...\", name: \"" ~ a ~ "_2\").");
    }

    return result;
}


// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/** Generate CREATE TABLE IF NOT EXISTS SQL for model M.
  *
  * All @field, @primaryKey, and @many2one fields become columns.
  * @related, @one2many, and @many2many fields are skipped (no DB column).
  *
  * Table-level UNIQUE and CHECK constraints from @uniqueTogether /
  * @checkConstraint are appended inside the CREATE TABLE block.
  *
  * CREATE INDEX statements from @index, @uniqueIndex, and @indexTogether
  * are appended after the CREATE TABLE block.
  *
  * Example:
  * ---
  * enum sql = modelDDL!Partner();
  * conn.exec(sql);
  * ---
  **/
string modelDDL(M)() {
    // Column definitions
    string cols;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (cols.length) cols ~= ",\n";
            cols ~= "    " ~ _buildColDef!(M, memberName)();
        }
    }}

    // Table-level constraints
    enum tableConstraints = _buildTableConstraints!M();

    string ddl = "CREATE TABLE IF NOT EXISTS " ~ ormTableName!M ~ " (\n" ~ cols;
    static if (tableConstraints.length)
        ddl ~= ",\n" ~ tableConstraints;
    ddl ~= "\n);";

    // Index statements
    enum indexSQL = _buildIndexSQL!M();
    static if (indexSQL.length)
        ddl ~= "\n" ~ indexSQL;

    return ddl;
}


/** Generate CREATE TABLE IF NOT EXISTS SQL for every model in registry Reg.
  *
  * Statements appear in registry binding order.  Ensure FK-referenced models
  * (e.g. the "one" side of @many2one) are bound before the models that
  * reference them, so the statements can be executed top-to-bottom.
  *
  * Example:
  * ---
  * enum schema = schemaSQL!AppRegistry();
  * conn.exec(schema);   // create all tables in one round-trip
  * ---
  **/
string schemaSQL(Reg)() {
    string result;
    static foreach (B; Reg._bindings) {{
        static if (is(B == Bind!(M, RepoTpl), M, alias RepoTpl)) {
            if (result.length) result ~= "\n\n";
            result ~= modelDDL!M();
        }
    }}
    return result;
}
