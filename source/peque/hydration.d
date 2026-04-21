/** Compile-time struct hydration from ResultRow.
  *
  * This module implements the dispatch chain used by ResultRow.as!T:
  *
  *  1. T has this(ref ResultRow)              → user-defined constructor
  *  2. T has static T fromRow(ref ResultRow)  → user-defined factory
  *  3. hasUDA!(T, model)                      → map @field/@primaryKey fields only (strict)
  *  4. hasUDA!(T, autoHydrate)                → map all fields by convention (permissive)
  *  5. (none of the above)                    → static assert with a helpful message
  *
  * This module is imported lazily inside ResultRow.as!T — you do not need to
  * import it directly unless you want camelToSnake for custom use.
  **/
module peque.hydration;

private import peque.result: ResultRow;
private import peque.model: model, field, primaryKey, autoHydrate,
    many2one, one2many, many2many, related, hasMany2OneUDA;


// ---------------------------------------------------------------------------
// camelToSnake
// ---------------------------------------------------------------------------

/** Convert a camelCase D identifier to snake_case at compile time.
  *
  * Rules: an uppercase letter at position > 0 is preceded by an underscore;
  * all letters are lowercased. Consecutive capitals each get their own underscore
  * (e.g. `myHTTPUrl` → `my_h_t_t_p_url`) — use `@field("col")` to override.
  *
  * Examples:
  * ---
  * static assert(camelToSnake("id")           == "id");
  * static assert(camelToSnake("name")         == "name");
  * static assert(camelToSnake("emailAddress") == "email_address");
  * static assert(camelToSnake("partnerId")    == "partner_id");
  * static assert(camelToSnake("createdAt")    == "created_at");
  * ---
  **/
string camelToSnake(string s) @safe pure nothrow {
    import std.ascii: isUpper, toLower;
    string result;
    foreach (size_t i, char c; s) {
        if (isUpper(c) && i > 0)
            result ~= '_';
        result ~= toLower(c);
    }
    return result;
}

///
unittest {
    static assert(camelToSnake("id")           == "id");
    static assert(camelToSnake("name")         == "name");
    static assert(camelToSnake("emailAddress") == "email_address");
    static assert(camelToSnake("partnerId")    == "partner_id");
    static assert(camelToSnake("createdAt")    == "created_at");
    static assert(camelToSnake("myURL")        == "my_u_r_l");   // override with @field if needed
}


// ---------------------------------------------------------------------------
// hydrateRow — public entry point
// ---------------------------------------------------------------------------

/** Hydrate a D struct T from a ResultRow using the dispatch chain.
  *
  * Do not call this directly — use ResultRow.as!T instead.
  **/
T hydrateRow(T)(ref ResultRow row) if (is(T == struct)) {
    import std.traits: hasUDA;

    static if (is(typeof({ ResultRow r; return T(r); }))) {
        // Case 1: T has a constructor accepting ResultRow
        return T(row);
    } else static if (is(typeof({ ResultRow r; return T.fromRow(r); }))) {
        // Case 2: T has a static factory fromRow(ref ResultRow)
        return T.fromRow(row);
    } else static if (hasUDA!(T, model)) {
        // Case 3: @model struct — only @field/@primaryKey annotated fields
        return _hydrateAnnotated!T(row);
    } else static if (hasUDA!(T, autoHydrate)) {
        // Case 4: @autoHydrate struct — all fields by convention, missing columns skipped
        return _hydrateConvention!T(row);
    } else {
        static assert(false,
            "Cannot hydrate `" ~ T.stringof ~ "` from ResultRow.\n" ~
            "Add one of:\n" ~
            "  • this(ref ResultRow) constructor\n" ~
            "  • static " ~ T.stringof ~ " fromRow(ref ResultRow)\n" ~
            "  • @model(\"table_name\") UDA on the struct (maps @field/@primaryKey fields)\n" ~
            "  • @autoHydrate UDA on the struct (maps all fields by convention)");
    }
}


// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/** Hydrate only @field- and @primaryKey-annotated fields.
  * Throws ColNotExistsError at runtime if an annotated field's column is absent.
  **/
private T _hydrateAnnotated(T)(ref ResultRow row) {
    import std.traits: FieldNameTuple, Fields, hasUDA, getUDAs;

    T result;
    static foreach (i, memberName; FieldNameTuple!T) {{   // double-brace: new scope per iteration
        alias FieldType = Fields!T[i];
        alias FieldDecl = __traits(getMember, T, memberName);

        // Column fields: @field, @primaryKey, or @many2one (FK column).
        // @related, @one2many, @many2many have no DB column — skipped implicitly
        // (they carry none of these UDAs, so the static if below is false).
        static if (hasUDA!(FieldDecl, field) || hasUDA!(FieldDecl, primaryKey) ||
                   hasMany2OneUDA!FieldDecl) {
            enum colName = _resolveColName!(FieldDecl, memberName);
            __traits(getMember, result, memberName) = row[colName].as!FieldType;
        }
    }}
    return result;
}


/** Hydrate all fields by camelCase→snake_case convention.
  * Silently skips fields whose columns are absent from the result.
  **/
private T _hydrateConvention(T)(ref ResultRow row) {
    import std.traits: FieldNameTuple, Fields;

    T result;
    static foreach (i, memberName; FieldNameTuple!T) {{   // double-brace: new scope per iteration
        alias FieldType = Fields!T[i];
        enum colName = camelToSnake(memberName);
        // _fieldIndex returns -1 when column is not in result
        immutable colIdx = row._fieldIndex(colName);
        if (colIdx >= 0)
            __traits(getMember, result, memberName) = row[colIdx].as!FieldType;
        // else: leave at zero/init value
    }}
    return result;
}


/** Resolve the SQL column name for a field declaration.
  *
  * Priority:
  *  1. @field("explicit_name") — use the explicit name
  *  2. Otherwise — camelToSnake(memberName)
  **/
private template _resolveColName(alias FieldDecl, string memberName) {
    import std.traits: getUDAs;
    alias _fieldUDAs = getUDAs!(FieldDecl, field);

    static if (_fieldUDAs.length > 0 && !is(_fieldUDAs[0]) &&
               _fieldUDAs[0].columnName.length > 0) {
        // @field("explicit_name") — instance UDA with a non-empty column name
        enum _resolveColName = _fieldUDAs[0].columnName;
    } else {
        // plain @field, @field(), or @primaryKey — use convention
        enum _resolveColName = camelToSnake(memberName);
    }
}
