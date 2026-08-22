/** Compile-time struct hydration from ResultRow.
  *
  * This module implements the dispatch chain used by ResultRow.as!T:
  *
  *  1. T has this(ref ResultRow)              → user-defined constructor
  *  2. T has static T fromRow(ref ResultRow)  → user-defined factory
  *  3. hasUDA!(T, model)                      → map @field/@primaryKey fields only (strict)
  *  4. hasUDA!(T, autoHydrate)                → map all fields by convention (permissive)
  *  5. any @field/@primaryKey member           → same strict mapping, no table claimed
  *  6. (none of the above)                    → static assert with a helpful message
  *
  * Cases 3 and 5 map identically; the difference is what @model MEANS. @model
  * marks a table — it is what isModel requires, so only such a struct can enter
  * a Registry or back a Repository. A projection or a RETURNING row wants the
  * same strict, aliasable mapping without claiming a table, and case 5 is that.
  *
  * This module is imported lazily inside ResultRow.as!T — you do not normally
  * need to import it directly.
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
  * An underscore is inserted before an uppercase letter that either follows a
  * lowercase letter or a digit, or begins a new word after a run of capitals —
  * so a run of capitals stays together: `myURL` is `my_url`, not `my_u_r_l`.
  *
  * Examples:
  * ---
  * static assert(camelToSnake("createdAt")  == "created_at");
  * static assert(camelToSnake("myURL")      == "my_url");
  * static assert(camelToSnake("HTTPServer") == "http_server");
  * ---
  *
  * Override with `@field("col")` whenever the result is not the column you want.
  **/
string camelToSnake(string s) @safe pure nothrow {
    import std.ascii: isUpper, isLower, isDigit, toLower;

    string result;
    foreach (size_t i, char c; s) {
        if (isUpper(c) && i > 0) {
            // A capital starts a new word when the previous character was not
            // itself a capital, or when the NEXT one is lowercase — that is the
            // last capital of a run, and so the first letter of the next word
            // (the S in HTTPServer).
            immutable prevIsPartOfRun = isUpper(s[i - 1]);
            immutable startsNextWord  = i + 1 < s.length && isLower(s[i + 1]);
            if (!prevIsPartOfRun || startsNextWord)
                result ~= '_';
        }
        result ~= toLower(c);
    }
    return result;
}

///
unittest {
    // The ordinary cases.
    static assert(camelToSnake("id")          == "id");
    static assert(camelToSnake("name")        == "name");
    static assert(camelToSnake("createdAt")   == "created_at");
    static assert(camelToSnake("partnerId")   == "partner_id");
    static assert(camelToSnake("emailAddress")== "email_address");

    // Runs of capitals stay together.
    static assert(camelToSnake("myURL")           == "my_url");
    static assert(camelToSnake("HTTPServer")      == "http_server");
    static assert(camelToSnake("HTTPSConnection") == "https_connection");
    static assert(camelToSnake("myURLPath")       == "my_url_path");
    static assert(camelToSnake("ID")              == "id");
    static assert(camelToSnake("apiKey")          == "api_key");
    static assert(camelToSnake("jsonData")        == "json_data");

    // A digit ends a word too.
    static assert(camelToSnake("line2Name") == "line2_name");
    static assert(camelToSnake("address2")  == "address2");

    // Already snake_case, or a single word, passes through.
    static assert(camelToSnake("created_at") == "created_at");
    static assert(camelToSnake("uuid")       == "uuid");
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
    } else static if (is(typeof({ ResultRow r; return T.fromRow(r); }) : T function())) {
        // Case 2: T has a static factory fromRow(ref ResultRow) returning T.
        // The return type is part of the test: gating on "does it compile"
        // alone matched a fromRow returning anything, and the call below then
        // failed with a bare "cannot implicitly convert" instead of falling
        // through to the dispatch-chain static assert.
        return T.fromRow(row);
    } else static if (hasUDA!(T, model)) {
        // Case 3: @model struct — only @field/@primaryKey annotated fields
        return _hydrateAnnotated!T(row);
    } else static if (hasUDA!(T, autoHydrate)) {
        // Case 4: @autoHydrate struct — all fields by convention, missing columns skipped
        return _hydrateConvention!T(row);
    } else static if (_hasAnnotatedColumn!T) {
        // Case 5: annotated fields but no @model — a decode shape rather than a
        // table. Same strict mapping as case 3; @model is what marks a struct as
        // a table (and is what isModel requires), so a projection or a
        // RETURNING row need not claim one.
        return _hydrateAnnotated!T(row);
    } else {
        static assert(false,
            "Cannot hydrate `" ~ T.stringof ~ "` from ResultRow.\n" ~
            "Add one of:\n" ~
            "  • this(ref ResultRow) constructor\n" ~
            "  • static " ~ T.stringof ~ " fromRow(ref ResultRow)\n" ~
            "  • @field/@primaryKey on the members you want mapped (decode-only shape)\n" ~
            "  • @model(\"table_name\") UDA on the struct (a table; also maps @field/@primaryKey)\n" ~
            "  • @autoHydrate UDA on the struct (maps all fields by convention)");
    }
}


// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/** Hydrate only @field- and @primaryKey-annotated fields.
  * Throws ColNotExistsError at runtime if an annotated field's column is absent.
  *
  * The optional colPrefix is prepended to every resolved column name before
  * looking it up in the ResultRow.  Used by the ORM join layer to read aliased
  * columns such as `__partner_id`, `__partner_name`, etc.
  **/
// True when T has at least one member carrying a column UDA. Distinguishes a
// decode shape from a struct that simply has no hydration markers at all — the
// latter must keep failing with the dispatch-chain message.
package(peque) template _hasAnnotatedColumn(T) {
    import std.traits: FieldNameTuple, hasUDA;
    enum bool _hasAnnotatedColumn = () {
        bool found = false;
        static foreach (memberName; FieldNameTuple!T) {{
            alias FieldDecl = __traits(getMember, T, memberName);
            if (hasUDA!(FieldDecl, field) || hasUDA!(FieldDecl, primaryKey) ||
                hasMany2OneUDA!FieldDecl)
                found = true;
        }}
        return found;
    }();
}

package(peque) T _hydrateAnnotated(T, string colPrefix = "")(ref ResultRow row) {
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
            enum colName = colPrefix ~ _resolveColName!(FieldDecl, memberName);
            __traits(getMember, result, memberName) = row[colName].as!FieldType;
        }
    }}
    return result;
}


/** Hydrate every field from its column, resolved like the annotated path.
  * Silently skips fields whose columns are absent from the result.
  **/
private T _hydrateConvention(T)(ref ResultRow row) {
    import std.traits: FieldNameTuple, Fields;

    T result;
    static foreach (i, memberName; FieldNameTuple!T) {{   // double-brace: new scope per iteration
        alias FieldType = Fields!T[i];
        alias FieldDecl = __traits(getMember, T, memberName);
        // Same resolver as the annotated path: @field("col") means the same
        // thing wherever it appears.
        enum colName = _resolveColName!(FieldDecl, memberName);
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
  *  2. Otherwise — camelToSnake of the D member name
  *
  * This is the single resolver: DDL, CRUD, QuerySet and hydration all go
  * through it, so a column cannot be named one way when written and another
  * when read back.
  **/
package(peque) template _resolveColName(alias FieldDecl, string memberName) {
    import std.traits: getUDAs;
    alias _fieldUDAs = getUDAs!(FieldDecl, field);

    static if (_fieldUDAs.length > 0 && !is(_fieldUDAs[0]))
        static assert(_fieldUDAs[0].columnName.length == 0 ||
                      _fieldUDAs[0].related.length == 0,
            "@field on `" ~ memberName ~ "` sets both a column name and " ~
            "related: — a member is either a column on this table or a value " ~
            "reached through a relation, not both.");

    static if (_fieldUDAs.length > 0 && !is(_fieldUDAs[0]) &&
               _fieldUDAs[0].columnName.length > 0) {
        // @field("explicit_name") — instance UDA with a non-empty column name
        enum _resolveColName = _fieldUDAs[0].columnName;
    } else static if (_fieldUDAs.length > 0 && !is(_fieldUDAs[0]) &&
                      _fieldUDAs[0].related.length > 0) {
        // @field(related: "rel.field") — a directive for building a query, not
        // for decoding one: the ORM aliases the path to this name, and
        // PostgreSQL never returns a dotted column name. Kept as its own branch
        // so the ORM's alias round-trip survives edits to the fallback below.
        enum _resolveColName = camelToSnake(memberName);
    } else {
        // plain @field, @field(), or @primaryKey — the member name converted
        enum _resolveColName = camelToSnake(memberName);
    }
}
