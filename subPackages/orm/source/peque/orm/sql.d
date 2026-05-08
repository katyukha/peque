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
private import peque.converter: PGValue, convertToPG;


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

/** Build multi-row VALUES placeholders for insertMany.
  *
  * buildMultiRowPlaceholders(3, 2) → "($1,$2,$3), ($4,$5,$6)"
  **/
string buildMultiRowPlaceholders(size_t nFields, size_t nRows) pure {
    string result;
    foreach (row; 0 .. nRows) {
        if (row > 0) result ~= ", ";
        result ~= "(";
        foreach (col; 0 .. nFields) {
            if (col > 0) result ~= ", ";
            result ~= "$" ~ (row * nFields + col + 1).to!string;
        }
        result ~= ")";
    }
    return result;
}

/** Internal — used by CRUDMixin.upsert. INSERT column list including the PK (PK first): "id, name, email_address". **/
string _buildInsertColListWithPk(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey))
            result = _colName!(F, memberName);
    }}
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F)
            result ~= ", " ~ _colName!(F, memberName);
    }}
    return result;
}

/** Internal — used by CRUDMixin.upsert. INSERT placeholders including PK ($1 for PK): "$1, $2, $3". **/
string _buildInsertPlaceholdersWithPk(M)() {
    string result = "$1";
    int n = 1;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            n++;
            result ~= ", $" ~ n.to!string;
        }
    }}
    return result;
}

/** Internal — used by CRUDMixin.upsert. D mixin expression for INSERT values including PK (PK first).
  * Example output: "record.id, record.name, record.emailAddress"
  **/
string _buildInsertValueExprWithPk(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey))
            result = "record." ~ memberName;
    }}
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F)
            result ~= ", record." ~ memberName;
    }}
    return result;
}

/** Internal — used by CRUDMixin.upsert. ON CONFLICT … DO UPDATE SET clause using the EXCLUDED pseudo-table.
  *
  * Generates "col=EXCLUDED.col, …" for all non-PK fields not in skipFields (D member names).
  * Returns "" when all fields are skipped — callers should static-assert against this.
  **/
string _buildExcludedSetClause(M, skipFields...)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            bool skip = false;
            static foreach (sf; skipFields)
                static if (is(typeof(sf) == string))
                    if (memberName == sf) skip = true;
            if (!skip) {
                if (result.length) result ~= ", ";
                result ~= _colName!(F, memberName) ~ "=EXCLUDED." ~ _colName!(F, memberName);
            }
        }
    }}
    return result;
}


/** Build a flat PGValue[] from a slice of records.
  *
  * Iterates records in order, then non-PK column fields in declaration order,
  * converting each field value via convertToPG.  The resulting array is the
  * parameter list for a multi-row INSERT built by buildMultiRowPlaceholders.
  **/
PGValue[] buildInsertParamsMany(M)(in M[] records) {
    PGValue[] params;
    params.reserve(records.length * countNonPkFields!M());
    foreach (ref rec; records) {
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static if (!hasUDA!(F, primaryKey) && _isColField!F)
                params ~= convertToPG(__traits(getMember, rec, memberName));
        }}
    }
    return params;
}


// ---------------------------------------------------------------------------
// ORM join / prefetch / partial-update helpers (package(peque.orm))
// ---------------------------------------------------------------------------

/** Runtime lookup: column name for D member name on M.
  *
  * Iterates all column fields of M (static foreach) and returns the SQL column
  * name for the member whose D name equals memberName. Falls back to
  * camelToSnake(memberName) for convention-based plain fields not found in
  * the model (accepts camelCase names that convert cleanly).
  **/
package(peque.orm) string _fieldColNameRuntime(M)(string memberName) {
    static foreach (mn; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, mn);
        static if (_isColField!F) {
            if (mn == memberName) return _colName!(F, mn);
        }
    }}
    return camelToSnake(memberName);
}

/** Return the SQL column name for fieldName on M if it is a DB column field.
  * Returns "" if fieldName is not found or is not a column field.
  **/
package(peque.orm) string _fieldColName(M, string fieldName)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (memberName == fieldName && _isColField!F)
            result = _colName!(F, memberName);
    }}
    return result;
}

/** Build "prefix.col1, prefix.col2, ..." for all DB column fields of M. **/
package(peque.orm) string _prefixedSelectList(M, string prefix)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (result.length) result ~= ", ";
            result ~= prefix ~ "." ~ _colName!(F, memberName);
        }
    }}
    return result;
}

/** Build "tableAlias.col AS colPrefixcol, ..." for all DB column fields of RelM.
  * Used to SELECT joined-model columns with a disambiguating alias prefix.
  **/
package(peque.orm) string _joinSelectExtras(RelM, string tableAlias, string colPrefix)() {
    string result;
    static foreach (memberName; FieldNameTuple!RelM) {{
        alias F = __traits(getMember, RelM, memberName);
        static if (_isColField!F) {
            if (result.length) result ~= ", ";
            result ~= tableAlias ~ "." ~ _colName!(F, memberName) ~
                      " AS " ~ colPrefix ~ _colName!(F, memberName);
        }
    }}
    return result;
}

/** Find the SQL column name of the FK field on M that has @many2one!(RelType, ...).
  * Returns "" when none is found.
  **/
package(peque.orm) string _findM2OFKColFor(M, RelType)() {
    import peque.model: many2one, OnDelete;
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasMany2OneUDA!F) {
            static foreach (uda; __traits(getAttributes, F)) {{
                static if (is(uda)) {
                    static if (is(uda == many2one!(U, od), U, OnDelete od) && is(U == RelType)) {
                        result = _colName!(F, memberName);
                    }
                }
            }}
        }
    }}
    return result;
}

/** Return the FK column name for a specific @related field on M.
  *
  * If @related("fkFieldName") carries an explicit FK field name, the column
  * for that field is returned.  Otherwise falls back to _findM2OFKColFor which
  * returns the first @many2one!(RelType) column found — fine for models with a
  * single FK to a given type, but ambiguous when there are two or more.
  **/
package(peque.orm) string _fkColForRelatedField(M, string relFieldName, RelType)() {
    import peque.model: related;
    alias RelFieldDecl = __traits(getMember, M, relFieldName);
    alias relatedUDAs  = getUDAs!(RelFieldDecl, related);
    static if (relatedUDAs.length > 0 && !is(relatedUDAs[0])
               && relatedUDAs[0].fkField.length > 0) {
        enum fkFN = relatedUDAs[0].fkField;
        alias FKDecl = __traits(getMember, M, fkFN);
        return _colName!(FKDecl, fkFN);
    } else {
        return _findM2OFKColFor!(M, RelType)();
    }
}

/** Return the D field name (not column name) of the @primaryKey field on M. **/
string ormPkFieldName(M)() {
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey))
            return memberName;
    }}
    assert(false, "No @primaryKey on " ~ M.stringof);
}
