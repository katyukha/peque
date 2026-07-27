/** Tests for Connection.escapeString().
  *
  * escapeString wraps PQescapeStringConn to produce a value safe for embedding
  * inside a SQL string literal (between single quotes).  It is NOT a substitute
  * for parameterized queries — use execParams for user-supplied values.
  * It is also NOT suitable for escaping LIKE patterns: % and _ are passed
  * through unchanged because they carry meaning only in LIKE context, not in
  * string literals.
  **/
module peque.tests.escape_string;

private import std.process: environment;
private import std.exception: assertThrown;
private import peque.connection: Connection;
private import peque.exception: QueryEscapingError;


private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


// ---------------------------------------------------------------------------
// Core contract: single quotes are doubled
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    // The SQL escaping rule: ' becomes '' so it does not close the literal.
    assert(c.escapeString("it's") == "it''s");
    assert(c.escapeString("'quoted'") == "''quoted''");

    // Multiple quotes in one string — each doubled independently.
    assert(c.escapeString("a'b'c") == "a''b''c");
    assert(c.escapeString("'''") == "''''''");
}


// ---------------------------------------------------------------------------
// Edge cases: empty string, no special characters
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    assert(c.escapeString("") == "");
    assert(c.escapeString("no special chars") == "no special chars");
    assert(c.escapeString("123") == "123");
}


// ---------------------------------------------------------------------------
// Characters that must pass through unchanged
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    // LIKE wildcards: escapeString does NOT escape them — they are only
    // meaningful in LIKE patterns, not inside plain string literals.
    assert(c.escapeString("50%") == "50%");
    assert(c.escapeString("col_name") == "col_name");

    // Other characters that should survive unmodified.
    assert(c.escapeString("line1\nline2") == "line1\nline2");
    assert(c.escapeString("tab\there") == "tab\there");
    assert(c.escapeString("emoji 🐇") == "emoji 🐇");
    assert(c.escapeString("café") == "café");
}


// ---------------------------------------------------------------------------
// End-to-end: escaped string is actually safe in a query
// ---------------------------------------------------------------------------

// Verify that a value containing a single quote, when escaped and embedded
// in a SQL literal, matches exactly the original value — no truncation,
// no injection side-effect.
unittest {
    auto c = makeConn();
    c.exec(`
        DROP TABLE IF EXISTS peque_test_escape;
        CREATE TABLE peque_test_escape (id serial PRIMARY KEY, label text);
        INSERT INTO peque_test_escape (label) VALUES ('O''Brien'), ('Smith'), ('it''s here');
    `);
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_test_escape");

    // Use escapeString to build a literal-safe WHERE clause.
    // The point: if escaping were wrong, the query would error or return the
    // wrong row.
    immutable needle = "O'Brien";
    auto sql = "SELECT label FROM peque_test_escape WHERE label = '" ~
               c.escapeString(needle) ~ "'";
    auto res = c.exec(sql);
    assert(res.ntuples == 1, "escaped value should match exactly one row");
    assert(res[0][0].as!string == needle, "retrieved value must equal original");

    // A value with no quotes must also work correctly.
    auto res2 = c.exec(
        "SELECT label FROM peque_test_escape WHERE label = '" ~
        c.escapeString("Smith") ~ "'");
    assert(res2.ntuples == 1);
    assert(res2[0][0].as!string == "Smith");
}


// ---------------------------------------------------------------------------
// Backslash round-trip: backslashes are preserved correctly for the connection
// ---------------------------------------------------------------------------

// PQescapeStringConn handles backslashes according to the connection's
// standard_conforming_strings setting (on by default since PG 9.1: literal).
// The end-to-end test is the authoritative check — if escaping is wrong for
// the active setting, the round-trip will either error or return the wrong value.
unittest {
    auto c = makeConn();
    c.exec(`
        DROP TABLE IF EXISTS peque_test_escape_bs;
        CREATE TABLE peque_test_escape_bs (id serial PRIMARY KEY, label text);
    `);
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_test_escape_bs");

    immutable values = [
        `C:\Users\alice`,
        `back\slash`,
        `trailing\`,
        `\leading`,
        `double\\slash`,
    ];

    foreach (v; values) {
        auto insertSql = "INSERT INTO peque_test_escape_bs (label) VALUES ('" ~
                         c.escapeString(v) ~ "')";
        c.exec(insertSql);
    }

    auto res = c.exec("SELECT label FROM peque_test_escape_bs ORDER BY id");
    assert(res.ntuples == values.length);
    foreach (i; 0 .. values.length)
        assert(res[cast(int)i][0].as!string == values[i],
            "backslash value did not round-trip correctly: " ~ values[i]);
}


// ---------------------------------------------------------------------------
// Null bytes: must be rejected before reaching PQescapeStringConn
// ---------------------------------------------------------------------------

// A null byte mid-string would be silently truncated when the escaped result
// is used in a C-string SQL query, potentially altering query semantics.
// escapeString must throw QueryEscapingError rather than silently truncate.
unittest {
    auto c = makeConn();

    assertThrown!QueryEscapingError(c.escapeString("hello\0world"),
        "null byte mid-string must be rejected");
    assertThrown!QueryEscapingError(c.escapeString("\0"),
        "lone null byte must be rejected");
    assertThrown!QueryEscapingError(c.escapeString("trailing\0"),
        "trailing null byte must be rejected");
}


// ---------------------------------------------------------------------------
// Injection attempt: a tautology payload must not escape the string literal
// ---------------------------------------------------------------------------

// This confirms that escapeString neutralises the canonical injection pattern.
// Note: for user-supplied values, prefer execParams — this test documents the
// escapeString contract for cases where string-building is unavoidable.
unittest {
    auto c = makeConn();
    c.exec(`
        DROP TABLE IF EXISTS peque_test_escape_inj;
        CREATE TABLE peque_test_escape_inj (id serial PRIMARY KEY, code text);
        INSERT INTO peque_test_escape_inj (code) VALUES ('safe');
    `);
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_test_escape_inj");

    // Without escaping, "' OR '1'='1" would return all rows.
    // With escaping it must return zero rows (no code equals that literal string).
    immutable payload = "' OR '1'='1";
    auto sql = "SELECT code FROM peque_test_escape_inj WHERE code = '" ~
               c.escapeString(payload) ~ "'";
    auto res = c.exec(sql);
    assert(res.ntuples == 0, "injection payload must not bypass the WHERE filter");
}
