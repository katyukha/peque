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
  * Index generation (appended after CREATE TABLE):
  * ---
  * @index                         string email;  // CREATE INDEX ON table (email)
  * @index(where: "active = true") string email;  // partial index
  * @uniqueIndex                   string slug;   // CREATE UNIQUE INDEX ON table (slug)
  * @ginIndex                      string tags;   // CREATE INDEX … USING gin (tags)
  * @gistIndex                     string loc;    // CREATE INDEX … USING gist (loc)
  * @hashIndex                     string code;   // CREATE INDEX … USING hash (code)
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
    OnDelete, many2one, hasMany2OneUDA,
    unique, check, pgDefault, pgNotNull,
    uniqueTogether, checkConstraint,
    index, uniqueIndex, ginIndex, gistIndex, hashIndex,
    indexTogether, uniqueIndexTogether;
private import peque.orm.sql: ormTableName, ormPkColName, _isColField, _colName;
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

    string colName = _colName!(F, memberName);

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
            static if (is(uda) && is(uda == many2one!(T, od), T, OnDelete od)) {
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
private string _buildTableConstraints(M)() {
    string result;

    static foreach (uda; __traits(getAttributes, M)) {{
        // @uniqueTogether!("col1", "col2", ...)
        static if (is(uda) && __traits(isSame, TemplateOf!uda, uniqueTogether)) {
            string cols;
            static foreach (col; uda.columns) {
                if (cols.length) cols ~= ", ";
                cols ~= col;
            }
            if (result.length) result ~= ",\n";
            result ~= "    UNIQUE (" ~ cols ~ ")";
        }
        // @checkConstraint("name", "expr")
        static if (is(typeof(uda) == checkConstraint)) {
            if (result.length) result ~= ",\n";
            result ~= "    CONSTRAINT " ~ uda.name ~ " CHECK (" ~ uda.expr ~ ")";
        }
    }}

    return result;
}

// Join a string[] with "_" — used to build index names from column lists.
private string _joinUnderscore(string[] cols) pure {
    string r;
    foreach (i, c; cols) { if (i) r ~= "_"; r ~= c; }
    return r;
}

private enum size_t PG_MAX_IDENT = 63;

// Build one CREATE [UNIQUE] INDEX IF NOT EXISTS statement.
// Called during CTFE — assert fires as a compile-time error when the name is too long.
// using_: access method; "btree" or "" → USING clause is omitted (btree is PG default).
private string _buildOneIndex(
    bool isUnique, string using_,
    string tbl, string cols, string where_, string idxName) pure
{
    assert(idxName.length <= PG_MAX_IDENT,
        "Generated index name \"" ~ idxName ~ "\" exceeds PostgreSQL's " ~
        "63-byte identifier limit. Shorten the table or column name.");
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
private string _tryBuildFieldIndex(alias uda, UDAType,
                                   bool isUnique, string using_, string prefix,
                                   string table, string col)() {
    static if (is(typeof(uda) == UDAType))
        return _buildOneIndex(isUnique, using_, table, col, uda.where,
                              prefix ~ table ~ "_" ~ col);
    else static if (is(uda == UDAType))
        return _buildOneIndex(isUnique, using_, table, col, "",
                              prefix ~ table ~ "_" ~ col);
    else
        return "";
}

// Build all CREATE INDEX statements for model M.
// Handles field-level: @index, @uniqueIndex, @ginIndex, @gistIndex, @hashIndex
//          model-level: @indexTogether, @uniqueIndexTogether
// All support an optional WHERE clause for partial indexes.
// Index names are deterministic; exceeding 63 bytes is a compile-time error.
private string _buildIndexSQL(M)() {
    string result;
    enum table = ormTableName!M;

    // Field-level: for each UDA on a column field, try each known index type.
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            enum col = _colName!(F, memberName);
            static foreach (uda; __traits(getAttributes, F)) {{
                result ~= _tryBuildFieldIndex!(uda, index,       false, "btree", "idx_",  table, col)();
                result ~= _tryBuildFieldIndex!(uda, uniqueIndex, true,  "btree", "uniq_", table, col)();
                result ~= _tryBuildFieldIndex!(uda, ginIndex,    false, "gin",   "gin_",  table, col)();
                result ~= _tryBuildFieldIndex!(uda, gistIndex,   false, "gist",  "gist_", table, col)();
                result ~= _tryBuildFieldIndex!(uda, hashIndex,   false, "hash",  "hash_", table, col)();
            }}
        }
    }}

    // Model-level: @indexTogether and @uniqueIndexTogether.
    // Two branches per template: type-as-value (where="") and instance (where=uda.where).
    static foreach (uda; __traits(getAttributes, M)) {{
        static if (is(uda) && __traits(isSame, TemplateOf!uda, indexTogether)) {
            string _cols; static foreach (c; uda.columns) { if (_cols.length) _cols ~= ", "; _cols ~= c; }
            enum _n = "idx_" ~ table ~ "_" ~ _joinUnderscore(uda.columns);
            result ~= _buildOneIndex(false, "btree", table, _cols, "", _n);
        }
        static if (!is(uda) && __traits(compiles, TemplateOf!(typeof(uda))) &&
                   __traits(isSame, TemplateOf!(typeof(uda)), indexTogether)) {
            string _cols; static foreach (c; uda.columns) { if (_cols.length) _cols ~= ", "; _cols ~= c; }
            enum _n = "idx_" ~ table ~ "_" ~ _joinUnderscore(uda.columns);
            result ~= _buildOneIndex(false, "btree", table, _cols, uda.where, _n);
        }

        static if (is(uda) && __traits(isSame, TemplateOf!uda, uniqueIndexTogether)) {
            string _cols; static foreach (c; uda.columns) { if (_cols.length) _cols ~= ", "; _cols ~= c; }
            enum _n = "uniq_" ~ table ~ "_" ~ _joinUnderscore(uda.columns);
            result ~= _buildOneIndex(true, "btree", table, _cols, "", _n);
        }
        static if (!is(uda) && __traits(compiles, TemplateOf!(typeof(uda))) &&
                   __traits(isSame, TemplateOf!(typeof(uda)), uniqueIndexTogether)) {
            string _cols; static foreach (c; uda.columns) { if (_cols.length) _cols ~= ", "; _cols ~= c; }
            enum _n = "uniq_" ~ table ~ "_" ~ _joinUnderscore(uda.columns);
            result ~= _buildOneIndex(true, "btree", table, _cols, uda.where, _n);
        }
    }}

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
