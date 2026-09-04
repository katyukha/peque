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

private import peque.hydration: camelToSnake, _resolveColName;
private import peque.model: model, field, primaryKey, hasMany2OneUDA;
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
  * you write IS the identifier. Converted names are all lowercase, so quoting
  * them is indistinguishable from emitting them bare. Only if you write mixed
  * case
  * (`@field("MyCol")`) do you get a case-sensitive column, which is then also
  * how you address one in a legacy schema.
  *
  * Generated aliases (_m, j0, __owner_*, index names) are NOT passed through
  * here: peque synthesises those itself, they can never collide with a keyword,
  * and quoting them would force the hydration lookup to match case exactly for
  * no benefit. Use _identSlug for names folded into such identifiers.
  **/
// PUBLIC despite the underscore: CRUDMixin's body is compiled in the
// INSTANTIATING module's scope, so every symbol it touches must be reachable
// from outside peque.orm. The underscore still marks it as internal — not part
// of the API anyone should call directly.
string _sqlIdent(string name) pure @safe {
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

// The SQL column name for a field. Delegates to hydration's resolver rather
// than restating the rule: a second copy is a second thing to keep in step, and
// a column named one way when written and another when read back is silent.
// Template form (not an alias) so it stays an eponymous `enum string` usable
// inside static foreach in CTFE functions.
package(peque.orm) template _colName(alias F, string memberName) {
    enum string _colName = _resolveColName!(F, memberName);
}

// True when a field maps to a DB column: @field, @primaryKey, or @many2one.
// The relation path declared by @field(related: "..."), or "" if none.
package(peque.orm) template _relatedPathOf(alias F) {
    static if (getUDAs!(F, field).length > 0 && !is(getUDAs!(F, field)[0]))
        enum _relatedPathOf = getUDAs!(F, field)[0].related;
    else
        enum _relatedPathOf = "";
}

package(peque.orm) template _isColField(alias F) {
    // Every model column passes through here, which is why the related: guard
    // lives here rather than in _colInfos — schema.d iterates FieldNameTuple
    // directly, so a guard there would miss DDL.
    static assert(_relatedPathOf!F.length == 0,
        "@field(related: \"" ~ _relatedPathOf!F ~ "\") on " ~ __traits(identifier, F) ~
        ": a model's fields are columns on its own table. Declare the relation " ~
        "with @many2one/@related, and use @field(related:) only on a select!DTO " ~
        "projection struct.");

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

// ---------------------------------------------------------------------------
// Column model — computed once, folded over by every builder below
// ---------------------------------------------------------------------------

/// One DB column of a model: its D member name, its raw (unquoted) SQL column
/// name, and whether it is the primary key.
package(peque.orm) struct _ColInfo {
    string member;
    string col;
    bool   isPk;
}

/** Every column field of M, in declaration order.
  *
  * The SQL builders below are folds over this one list rather than each
  * repeating the `static foreach` + `!hasUDA!(F, primaryKey) && _isColField!F`
  * test, so column selection lives in exactly one spot instead of eight that
  * have to be kept in step.
  **/
package(peque.orm) template _colInfos(M) {
    private static _ColInfo[] _collect() {
        _ColInfo[] result;
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static if (_isColField!F)
                result ~= _ColInfo(memberName, _colName!(F, memberName),
                                   hasUDA!(F, primaryKey));
        }}
        return result;
    }
    enum _ColInfo[] _colInfos = _collect();
}

private _ColInfo[] _selectCols(_ColInfo[] all, bool wantPk) pure {
    _ColInfo[] result;
    foreach (ci; all) if (ci.isPk == wantPk) result ~= ci;
    return result;
}

/// Non-primary-key columns of M, in declaration order.
package(peque.orm) enum _nonPkCols(M) = _selectCols(_colInfos!M, false);

/// Primary-key columns of M (see _pkInfo — exactly one is required).
package(peque.orm) enum _pkCols(M) = _selectCols(_colInfos!M, true);

/** The single primary-key column of M.
  *
  * Enforcing "exactly one" here closes a real inconsistency: with two
  * @primaryKey fields, ormPkColName/ormPkFieldName picked the FIRST while
  * buildInsertValueExpr!(M, true) kept the LAST, so upsert-by-PK sent one
  * field's value into the other's column.
  **/
package(peque.orm) template _pkInfo(M) {
    static assert(_pkCols!M.length > 0,
        M.stringof ~ " has no @primaryKey field. Annotate exactly one column " ~
        "field with @primaryKey to use it as a repository model.");
    static assert(_pkCols!M.length == 1,
        M.stringof ~ " has " ~ _pkCols!M.length.to!string ~ " @primaryKey " ~
        "fields; exactly one is required. Composite primary keys are not " ~
        "supported — drop @primaryKey from all but one field.");
    enum _ColInfo _pkInfo = _pkCols!M[0];
}


// ---------------------------------------------------------------------------
// SQL fragment builders
// ---------------------------------------------------------------------------

/** SQL column name for a model field — the supported field → column resolver.
  *
  * Applies the same rule as everything else peque emits: `@field("col")` if
  * present, otherwise `camelToSnake` of the member name. Public because code
  * outside peque legitimately needs it — a caller that reads
  * `@uniqueTogether!(...)` off a model and derives something from it (the
  * constraint name PostgreSQL will generate, for instance) must resolve the
  * field names first, and reimplementing the rule is how the two drift apart.
  *
  * Unquoted, for folding into derived identifiers; use ormTableName-style
  * quoting when embedding in SQL.
  **/
template ormColumnName(M, string fieldName) {
    enum string ormColumnName = () {
        foreach (ci; _colInfos!M) if (ci.member == fieldName) return ci.col;
        return "";
    }();
    static assert(ormColumnName.length > 0,
        "ormColumnName!(" ~ M.stringof ~ ", \"" ~ fieldName ~ "\"): not a " ~
        "column field on " ~ M.stringof ~ ". Fields: " ~ _modelFieldNames!M() ~ ".");
}

/// Raw primary-key column name for model M (no quoting) — for building derived
/// identifiers such as joined-column aliases.
/// Honors a `@field("col")` override on the primary-key member.
string ormPkColNameRaw(M)() {
    return _pkInfo!M.col;
}

/// Primary-key column name for model M, ready to embed in SQL.
string ormPkColName(M)() {
    return _sqlIdent(_pkInfo!M.col);
}

/// SELECT column list: "id, name, partner_id, ..."
string buildSelectList(M)() {
    string result;
    foreach (ci; _colInfos!M) {
        if (result.length) result ~= ", ";
        result ~= _sqlIdent(ci.col);
    }
    return result;
}

/// Non-PK column list for INSERT: "name, code, partner_id"
string buildInsertColList(M)() {
    string result;
    foreach (ci; _nonPkCols!M) {
        if (result.length) result ~= ", ";
        result ~= _sqlIdent(ci.col);
    }
    return result;
}

/// INSERT placeholders: "$1, $2, $3"
/// When withPk is true, $1 is reserved for the PK (placed first) and
/// non-PK fields follow as $2, $3, …
string buildInsertPlaceholders(M, bool withPk = false)() {
    string result;
    static if (withPk) result = "$1";
    int n = withPk ? 1 : 0;
    foreach (_; _nonPkCols!M) {
        n++;
        if (result.length) result ~= ", ";
        result ~= "$" ~ n.to!string;
    }
    return result;
}

/// UPDATE SET clause: "name = $1, code = $2, partner_id = $3"
string buildUpdateSetClause(M)() {
    int n = 0;
    string result;
    foreach (ci; _nonPkCols!M) {
        n++;
        if (result.length) result ~= ", ";
        result ~= _sqlIdent(ci.col) ~ " = $" ~ n.to!string;
    }
    return result;
}

/// D expression for non-PK field values used in INSERT mixin:
/// "record.name, record.code, record.partnerId"
/// When withPk is true, the PK field is prepended:
/// "record.id, record.name, record.code, record.partnerId"
string buildInsertValueExpr(M, bool withPk = false)() {
    string result;
    static if (withPk) result = "record." ~ _pkInfo!M.member;
    foreach (ci; _nonPkCols!M) {
        if (result.length) result ~= ", ";
        result ~= "record." ~ ci.member;
    }
    return result;
}

/// D expression for UPDATE: non-PK fields first, then PK last (for WHERE $N).
/// "record.name, record.code, record.partnerId, record.id"
string buildUpdateValueExpr(M)() {
    string result;
    foreach (ci; _nonPkCols!M) {          // → $1 … $N
        if (result.length) result ~= ", ";
        result ~= "record." ~ ci.member;
    }
    if (result.length) result ~= ", ";     // PK → $N+1, used in WHERE
    result ~= "record." ~ _pkInfo!M.member;
    return result;
}

/// Number of non-PK column fields (used to compute PK placeholder index in UPDATE).
size_t countNonPkFields(M)() {
    return _nonPkCols!M.length;
}

/** Comma-separated placeholder list: "$1, $2, $3".
  *
  * start is the first placeholder number (1-based), so a caller that has
  * already bound N parameters passes start = N + 1.
  **/
string buildPlaceholderList(size_t count, size_t start = 1) pure {
    string result;
    foreach (i; 0 .. count) {
        if (i > 0) result ~= ", ";
        result ~= "$" ~ (start + i).to!string;
    }
    return result;
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
    foreach (ci; _nonPkCols!M) {
        bool skip = false;
        static foreach (sf; skipFields)
            static if (is(typeof(sf) == string))
                if (ci.member == sf) skip = true;
        if (skip) continue;
        if (result.length) result ~= ", ";
        result ~= _sqlIdent(ci.col) ~ "=EXCLUDED." ~ _sqlIdent(ci.col);
    }
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
    params.reserve(records.length * _nonPkCols!M.length);
    foreach (ref rec; records) {
        // static foreach: ci.member must be known at compile time for getMember.
        static foreach (ci; _nonPkCols!M)
            params ~= convertToPG(__traits(getMember, rec, ci.member));
    }
    return params;
}


// ---------------------------------------------------------------------------
// ORM join / prefetch / partial-update helpers (package(peque.orm))
// ---------------------------------------------------------------------------

/** Runtime lookup: column name for D member name on M.
  *
  * Iterates all column fields of M (static foreach) and returns the SQL column
  * name for the member whose D name equals memberName, falling back to
  * camelToSnake(memberName) for names not declared on the model.
  **/
package(peque.orm) string _fieldColNameRuntime(M)(string memberName) {
    import std.exception: enforce;
    import std.string: indexOf;
    import peque.exception: QueryClientError, QueryError;

    static foreach (mn; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, mn);
        static if (_isColField!F) {
            if (mn == memberName) return _sqlIdent(_colName!(F, mn));
        }
    }}
    // A leaf name containing '.' means a relation path reached a place expecting
    // a plain field. Quoting it would splice a bogus identifier into the SQL,
    // so reject it where the mistake is still attributable.
    enforce!QueryClientError(indexOf(memberName, '.') < 0,
        "'" ~ memberName ~ "' is not a column on " ~ M.stringof ~ " and contains a " ~
        "'.', so it cannot be a column name either — a relation path was passed " ~
        "where a field name was expected.");
    return _sqlIdent(camelToSnake(memberName));
}

/** Return the SQL column name for fieldName on M if it is a DB column field.
  * Returns "" if fieldName is not found or is not a column field.
  **/
// PUBLIC despite the underscore: CRUDMixin's body is compiled in the
// INSTANTIATING module's scope, so every symbol it touches must be reachable
// from outside peque.orm. The underscore still marks it as internal — not part
// of the API anyone should call directly.
string _fieldColName(M, string fieldName)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (memberName == fieldName && _isColField!F)
            result = _sqlIdent(_colName!(F, memberName));
    }}
    return result;
}

/** As _fieldColName, but unquoted — for comparing against index column lists,
  * which are raw names. Returns "" if fieldName is not a column field on M. **/
// PUBLIC despite the underscore: CRUDMixin's body is compiled in the
// INSTANTIATING module's scope, so every symbol it touches must be reachable
// from outside peque.orm. The underscore still marks it as internal — not part
// of the API anyone should call directly.
string _fieldColNameRaw(M, string fieldName)() {
    string result;
    static foreach (memberName; FieldNameTuple!M) {{
        alias F = __traits(getMember, M, memberName);
        static if (memberName == fieldName && _isColField!F)
            result = _colName!(F, memberName);
    }}
    return result;
}

/** Comma-separated D field names of M that map to columns — for diagnostics.
  * Public for the same reason as _fieldColNameRaw above.
  **/
string _modelFieldNames(M)() {
    string r;
    foreach (ci; _colInfos!M) { if (r.length) r ~= ", "; r ~= ci.member; }
    return r;
}

/// The D field of M whose column is `col`, or "" — the inverse of _colName.
string _fieldForColumnName(M)(in string col) {
    foreach (ci; _colInfos!M) if (ci.col == col) return ci.member;
    return "";
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
// Every @many2one field on M whose target is RelType, in declaration order.
package(peque.orm) template _m2oFksFor(M, RelType) {
    private static _ColInfo[] _collect() {
        import peque.model: many2one, OnDelete, many2oneUDAType;
        _ColInfo[] result;
        static foreach (memberName; FieldNameTuple!M) {{
            alias F = __traits(getMember, M, memberName);
            static if (hasMany2OneUDA!F) {
                static foreach (uda; __traits(getAttributes, F)) {{
                    static if (is(many2oneUDAType!uda == many2one!(U, od), U, OnDelete od) &&
                               is(U == RelType))
                        result ~= _ColInfo(memberName, _colName!(F, memberName), false);
                }}
            }
        }}
        return result;
    }
    enum _ColInfo[] _m2oFksFor = _collect();
}

private string _joinMemberNames(_ColInfo[] cols) pure {
    string result;
    foreach (i, ci; cols) {
        if (i) result ~= ", ";
        result ~= ci.member;
    }
    return result;
}

package(peque.orm) string _findM2OFKColFor(M, RelType)() {
    enum fks = _m2oFksFor!(M, RelType);
    // Reached only when a @related field gave no explicit fkField, so more than
    // one candidate cannot be resolved. Picking one silently would contradict
    // the caller's documented "the single FK" promise.
    static assert(fks.length <= 1,
        M.stringof ~ " has " ~ fks.length.to!string ~ " @many2one fields " ~
        "targeting " ~ RelType.stringof ~ " (" ~ _joinMemberNames(fks) ~ "), so " ~
        "the foreign key for a bare @related is ambiguous. Name the backing " ~
        "field explicitly, e.g. @related(\"" ~ fks[0].member ~ "\").");
    return fks.length ? _sqlIdent(fks[0].col) : "";
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
        return _sqlIdent(_colName!(FKDecl, fkFN));
    } else {
        return _findM2OFKColFor!(M, RelType)();
    }
}

/** Return the D field name (not column name) of the @primaryKey field on M. **/
string ormPkFieldName(M)() {
    return _pkInfo!M.member;
}
