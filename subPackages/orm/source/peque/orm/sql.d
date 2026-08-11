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
// SQL identifier rendering
// ---------------------------------------------------------------------------

/** Render `name` as a SQL identifier.
  *
  * Every identifier naming a real database object — table, column, junction
  * table and its keys, constraint name — is double-quoted unconditionally. That
  * is the whole rule: no keyword list to keep in sync with PostgreSQL releases,
  * no per-name special cases, and no way for a field called `order`, `end`,
  * `user` or `check` to produce invalid SQL.
  *
  * Because peque quotes in DDL and in every statement it generates, the two
  * always agree, so no manual quoting is ever needed in @model / @field.
  *
  * Consequence worth knowing: quoted identifiers are case-exact, so the string
  * you write IS the identifier. For a lowercase name — everything camelToSnake
  * produces — quoting is indistinguishable from emitting it bare, so the usual
  * snake_case model needs no thought. Only if you deliberately write mixed case
  * (`@field("MyCol")`) do you get a case-sensitive column, which is then also
  * how you address one in a legacy schema.
  *
  * Generated aliases (_m, j0, __owner_*, index names) are NOT passed through
  * here: peque synthesises those itself, they can never collide with a keyword,
  * and quoting them would force the hydration lookup to match case exactly for
  * no benefit. Use _identSlug for names folded into such identifiers.
  **/
package(peque.orm) string _sqlIdent(string name) pure @safe {
    string quoted = "\"";
    foreach (char c; name) {
        if (c == '"') quoted ~= '"';    // double an embedded quote
        quoted ~= c;
    }
    return quoted ~ "\"";
}

/** Reduce `name` to characters safe inside a *derived* identifier.
  *
  * Used where a name is concatenated into a larger identifier that must itself
  * stay bare — generated index names and joined-column aliases. Quoting is
  * wrong there (`idx_t_"order"` is not a valid identifier), so quotes and any
  * other stray characters are dropped. Case is preserved so that generated
  * aliases keep matching what the hydration layer looks up.
  **/
package(peque.orm) string _identSlug(string name) pure @safe {
    string result;
    foreach (char c; name) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_')
            result ~= c;
    }
    return result;
}

unittest {
    // One rule, applied to every identifier.
    assert(_sqlIdent("name")       == `"name"`);
    assert(_sqlIdent("partner_id") == `"partner_id"`);
    assert(_sqlIdent("order")      == `"order"`);
    assert(_sqlIdent("end")        == `"end"`);
    assert(_sqlIdent("check")      == `"check"`);
    // Case is preserved: what you write is the identifier.
    assert(_sqlIdent("MyCol")      == `"MyCol"`);
    // Names that could never work bare now just work.
    assert(_sqlIdent("weird col")  == `"weird col"`);
    assert(_sqlIdent("2fast")      == `"2fast"`);
    // An embedded quote is doubled, so a hostile UDA string cannot break out.
    assert(_sqlIdent(`a"b`)        == `"a""b"`);
    assert(_sqlIdent(`x"; DROP TABLE y; --`) == `"x""; DROP TABLE y; --"`);
    assert(_sqlIdent("")           == `""`);

    // Slugs stay usable inside a bigger identifier.
    assert(_identSlug("order")     == "order");
    assert(_identSlug(`"order"`)   == "order");
    assert(_identSlug("MyCol")     == "MyCol");
    assert(_identSlug("weird col") == "weirdcol");
}


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

/// Raw table name for model M, exactly as written in the @model("table") UDA.
/// Use only where the name is folded into a *derived* identifier (index names);
/// for SQL emission use ormTableName, which quotes reserved words.
template ormTableNameRaw(M) {
    enum string ormTableNameRaw = getUDAs!(M, model)[0].tableName;
}

/// Table name for model M, ready to embed in SQL (quoted only if it has to be).
template ormTableName(M) {
    enum string ormTableName = _sqlIdent(ormTableNameRaw!M);
}

/// Raw primary-key column name for model M (no quoting) — for building derived
/// identifiers such as joined-column aliases.
/// Honors a `@field("col")` override on the primary-key member.
string ormPkColNameRaw(M)() {
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasUDA!(F, primaryKey))
            return _colName!(F, memberName);
    }}
    assert(false, "No @primaryKey field on " ~ M.stringof);
}

/// Primary-key column name for model M, ready to embed in SQL.
string ormPkColName(M)() {
    return _sqlIdent(ormPkColNameRaw!M());
}

/// SELECT column list: "id, name, partner_id, ..."
string buildSelectList(M)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (_isColField!F) {
            if (result.length) result ~= ", ";
            result ~= _sqlIdent(_colName!(F, memberName));
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
            result ~= _sqlIdent(_colName!(F, memberName));
        }
    }}
    return result;
}

/// INSERT placeholders: "$1, $2, $3"
/// When withPk is true, $1 is reserved for the PK (placed first) and
/// non-PK fields follow as $2, $3, …
string buildInsertPlaceholders(M, bool withPk = false)() {
    string result;
    static if (withPk) result = "$1";
    int n = withPk ? 1 : 0;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (!hasUDA!(F, primaryKey) && _isColField!F) {
            n++;
            if (result.length) result ~= ", ";
            result ~= "$" ~ n.to!string;
        }
    }}
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
            result ~= _sqlIdent(_colName!(F, memberName)) ~ " = $" ~ n.to!string;
        }
    }}
    return result;
}

/// D expression for non-PK field values used in INSERT mixin:
/// "record.name, record.code, record.partnerId"
/// When withPk is true, the PK field is prepended:
/// "record.id, record.name, record.code, record.partnerId"
string buildInsertValueExpr(M, bool withPk = false)() {
    string result;
    static if (withPk) {
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static if (hasUDA!(F, primaryKey))
                result = "record." ~ memberName;
        }}
    }
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
                result ~= _sqlIdent(_colName!(F, memberName)) ~
                          "=EXCLUDED." ~ _sqlIdent(_colName!(F, memberName));
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
    import std.exception: enforce;
    import std.string: indexOf;
    import peque.exception: QueryError;

    static foreach (mn; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, mn);
        static if (_isColField!F) {
            if (mn == memberName) return _sqlIdent(_colName!(F, mn));
        }
    }}
    // A leaf name containing '.' means a relation path reached a place expecting
    // a plain field. camelToSnake would pass it straight through and the caller
    // would splice it into SQL as a qualified name (fj1.c.d → schema.table.col).
    enforce!QueryError(indexOf(memberName, '.') < 0,
        "'" ~ memberName ~ "' is not a column on " ~ M.stringof ~ " and contains a " ~
        "'.', so it cannot be a column name either — a relation path was passed " ~
        "where a field name was expected.");
    return _sqlIdent(camelToSnake(memberName));
}

/** Return the SQL column name for fieldName on M if it is a DB column field.
  * Returns "" if fieldName is not found or is not a column field.
  **/
package(peque.orm) string _fieldColName(M, string fieldName)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (memberName == fieldName && _isColField!F)
            result = _sqlIdent(_colName!(F, memberName));
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
            result ~= prefix ~ "." ~ _sqlIdent(_colName!(F, memberName));
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
            // Left side is a column reference (quote it); right side builds a
            // new alias that must stay bare — hydration looks it up by that
            // exact name via ResultRow._fieldIndex.
            result ~= tableAlias ~ "." ~ _sqlIdent(_colName!(F, memberName)) ~
                      " AS " ~ colPrefix ~ _identSlug(_colName!(F, memberName));
        }
    }}
    return result;
}

/** Find the SQL column name of the FK field on M that has @many2one!(RelType, ...).
  * Returns "" when none is found.
  **/
package(peque.orm) string _findM2OFKColFor(M, RelType)() {
    import peque.model: many2one, OnDelete, many2oneUDAType;
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (hasMany2OneUDA!F) {
            static foreach (uda; __traits(getAttributes, F)) {{
                static if (is(many2oneUDAType!uda == many2one!(U, od), U, OnDelete od) &&
                           is(U == RelType)) {
                    result = _sqlIdent(_colName!(F, memberName));
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
