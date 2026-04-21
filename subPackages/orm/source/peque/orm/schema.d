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
  * FK columns (@many2one) get REFERENCES automatically:
  * ---
  * @many2one!(Partner) int   partnerId;   // INTEGER NOT NULL REFERENCES res_partner(id)
  * @many2one!(Partner) Nullable!int orgId; // INTEGER REFERENCES res_partner(id)
  * ---
  *
  * Statement order in schemaSQL equals the registry binding order — ensure
  * FK-referenced tables appear before the tables that reference them.
  *
  * Planned (Phase 2): @unique, @check, @default, @index, @uniqueIndex,
  * @uniqueTogether, multi-column constraints.
  **/
module peque.orm.schema;

private import std.traits: FieldNameTuple, hasUDA, getUDAs;
private import std.typecons: Nullable;

private import peque.model: model, field, primaryKey, pgType,
                             many2one, hasMany2OneUDA;
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

// Build one column definition: "col_name TYPE [NOT NULL] [PRIMARY KEY] [REFERENCES ...]"
// Takes (M, memberName) rather than alias F to avoid "requires instance" errors
// when called from inside static foreach in CTFE functions.
private string _buildColDef(M, string memberName)() {
    alias F = __traits(getMember, M, memberName);
    alias FType = typeof(F);

    string colName = _colName!(F, memberName);

    // --- Determine type string ---
    string typeName;
    alias pgTypeUDAs = getUDAs!(F, pgType);
    static if (pgTypeUDAs.length > 0) {
        // Explicit @pgType override — use verbatim, skip SERIAL substitution
        typeName = pgTypeUDAs[0].typeName;
    } else static if (hasUDA!(F, primaryKey)) {
        // Auto-increment PK: int → SERIAL, long → BIGSERIAL, others → base type
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

    // --- Nullability and PRIMARY KEY ---
    static if (hasUDA!(F, primaryKey)) {
        result ~= " PRIMARY KEY";   // SERIAL/BIGSERIAL already implies NOT NULL
    } else static if (!_isNullable!FType) {
        result ~= " NOT NULL";
    }

    // --- REFERENCES for @many2one ---
    static if (hasMany2OneUDA!F) {
        static foreach (uda; __traits(getAttributes, F)) {{
            static if (is(uda) && is(uda == many2one!T, T)) {
                result ~= " REFERENCES " ~ ormTableName!T ~
                          "(" ~ ormPkColName!T() ~ ")";
            }
        }}
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
  * Example:
  * ---
  * enum sql = modelDDL!Partner();
  * conn.exec(sql);
  * ---
  **/
string modelDDL(M)() {
    string cols;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (cols.length) cols ~= ",\n";
            cols ~= "    " ~ _buildColDef!(M, memberName)();
        }
    }}
    return "CREATE TABLE IF NOT EXISTS " ~ ormTableName!M ~
           " (\n" ~ cols ~ "\n);";
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
