/** Compile-time SQL generation helpers for peque:orm.
  *
  * All public functions are pure CTFE functions — call them in `enum` context
  * to obtain compile-time string constants.
  *
  * Usage:
  * ---
  * enum sel  = buildSelectList!Partner();   // "id, name, email_address"
  * enum ins  = buildInsertColList!Partner(); // "name, email_address"
  * ---
  **/
module peque.orm.sql;

private import peque.model: model, field, primaryKey, hasMany2OneUDA;
private import peque.hydration: camelToSnake;
private import std.traits: FieldNameTuple, hasUDA, getUDAs;
private import std.conv: to;


// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Resolve the SQL column name for a field (mirrors hydration._resolveColName).
// Priority: @field("explicit") > camelToSnake(memberName).
// Template form (not a function) to avoid "requires instance" errors inside
// static foreach in CTFE functions.
package(peque.orm) template _colName(alias F, string memberName) {
    alias _fudas = getUDAs!(F, field);
    static if (_fudas.length > 0 && !is(_fudas[0]) && _fudas[0].columnName.length > 0)
        enum string _colName = _fudas[0].columnName;
    else
        enum string _colName = camelToSnake(memberName);
}

// True when a field maps to a DB column: @field, @primaryKey, or @many2one.
package(peque.orm) template _isColField(alias F) {
    enum bool _isColField =
        hasUDA!(F, field) || hasUDA!(F, primaryKey) || hasMany2OneUDA!F;
}


// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

/// Table name for model M (from @model("table") UDA).
template ormTableName(M) {
    enum string ormTableName = getUDAs!(M, model)[0].tableName;
}

/// Primary-key column name for model M.
string ormPkColName(M)() {
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey))
            return camelToSnake(memberName);
    }}
    assert(false, "No @primaryKey field on " ~ M.stringof);
}

/// SELECT column list: "id, name, partner_id, ..."
string buildSelectList(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (result.length) result ~= ", ";
            result ~= _colName!(F, memberName);
        }
    }}
    return result;
}

/// Non-PK column list for INSERT: "name, code, partner_id"
string buildInsertColList(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            if (result.length) result ~= ", ";
            result ~= _colName!(F, memberName);
        }
    }}
    return result;
}

/// INSERT placeholders: "$1, $2, $3"
string buildInsertPlaceholders(M)() {
    int n = 0;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F)
            n++;
    }}
    string result;
    foreach (i; 1 .. n + 1) {
        if (result.length) result ~= ", ";
        result ~= "$" ~ i.to!string;
    }
    return result;
}

/// UPDATE SET clause: "name = $1, code = $2, partner_id = $3"
string buildUpdateSetClause(M)() {
    int n = 0;
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            n++;
            if (result.length) result ~= ", ";
            result ~= _colName!(F, memberName) ~ " = $" ~ n.to!string;
        }
    }}
    return result;
}

/// D expression for non-PK field values used in INSERT mixin:
/// "record.name, record.code, record.partnerId"
string buildInsertValueExpr(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            if (result.length) result ~= ", ";
            result ~= "record." ~ memberName;
        }
    }}
    return result;
}

/// D expression for UPDATE: non-PK fields first, then PK last (for WHERE $N).
/// "record.name, record.code, record.partnerId, record.id"
string buildUpdateValueExpr(M)() {
    string result;
    // Non-PK fields → $1 … $N
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            if (result.length) result ~= ", ";
            result ~= "record." ~ memberName;
        }
    }}
    // PK field → $N+1 (used in WHERE clause)
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey)) {
            if (result.length) result ~= ", ";
            result ~= "record." ~ memberName;
        }
    }}
    return result;
}

/// Number of non-PK column fields (used to compute PK placeholder index in UPDATE).
size_t countNonPkFields(M)() {
    size_t n = 0;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F)
            n++;
    }}
    return n;
}
