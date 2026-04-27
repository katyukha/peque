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
  * @index       string email;   // CREATE INDEX ON table (email);
  * @uniqueIndex string slug;    // CREATE UNIQUE INDEX ON table (slug);
  *
  * @indexTogether!("partner_id", "status")
  * @model("sale_order")
  * struct Order { ... }         // CREATE INDEX ON sale_order (partner_id, status);
  * ---
  *
  * Statement order in schemaSQL equals the registry binding order — ensure
  * FK-referenced tables appear before the tables that reference them.
  **/
module peque.orm.schema;

private import std.traits: FieldNameTuple, hasUDA, getUDAs, TemplateOf;
private import std.typecons: Nullable;
private import std.json: JSONValue;

private import peque.model:
    model, field, primaryKey, pgType,
    OnDelete, many2one, hasMany2OneUDA,
    unique, check, pgDefault, pgNotNull,
    uniqueTogether, checkConstraint, index, uniqueIndex, indexTogether;
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

// Build the CREATE INDEX IF NOT EXISTS statements for model M.
// Generated index names are deterministic:
//   @index / @uniqueIndex on a field : idx_{table}_{col} / uniq_{table}_{col}
//   @indexTogether on the model      : idx_{table}_{col1}_{col2}_...
// A compile-time error is raised if any generated name exceeds 63 bytes.
private string _buildIndexSQL(M)() {
    string result;
    enum table = ormTableName!M;

    // Field-level @index / @uniqueIndex
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            enum col = _colName!(F, memberName);
            static if (hasUDA!(F, index)) {
                enum _n = "idx_" ~ table ~ "_" ~ col;
                static assert(_n.length <= PG_MAX_IDENT,
                    "Generated index name \"" ~ _n ~ "\" is " ~ _n.length.stringof ~
                    " bytes, exceeding PostgreSQL's 63-byte limit. " ~
                    "Shorten the table or column name.");
                result ~= "CREATE INDEX IF NOT EXISTS " ~ _n ~
                          " ON " ~ table ~ " (" ~ col ~ ");\n";
            }
            static if (hasUDA!(F, uniqueIndex)) {
                enum _n = "uniq_" ~ table ~ "_" ~ col;
                static assert(_n.length <= PG_MAX_IDENT,
                    "Generated index name \"" ~ _n ~ "\" is " ~ _n.length.stringof ~
                    " bytes, exceeding PostgreSQL's 63-byte limit. " ~
                    "Shorten the table or column name.");
                result ~= "CREATE UNIQUE INDEX IF NOT EXISTS " ~ _n ~
                          " ON " ~ table ~ " (" ~ col ~ ");\n";
            }
        }
    }}

    // Model-level @indexTogether!("col1", "col2", ...)
    static foreach (uda; __traits(getAttributes, M)) {{
        static if (is(uda) && __traits(isSame, TemplateOf!uda, indexTogether)) {
            string cols;
            static foreach (col; uda.columns) {
                if (cols.length) cols ~= ", ";
                cols ~= col;
            }
            enum _n = "idx_" ~ table ~ "_" ~ _joinUnderscore(uda.columns);
            static assert(_n.length <= PG_MAX_IDENT,
                "Generated index name \"" ~ _n ~ "\" is " ~ _n.length.stringof ~
                " bytes, exceeding PostgreSQL's 63-byte limit. " ~
                "Shorten the table or column names.");
            result ~= "CREATE INDEX IF NOT EXISTS " ~ _n ~
                      " ON " ~ table ~ " (" ~ cols ~ ");\n";
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
