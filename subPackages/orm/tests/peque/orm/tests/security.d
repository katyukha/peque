/** SQL-injection safety tests for peque:orm.
  *
  * Values: injection payloads passed as predicate *values* through the ORM
  * (where!, whereIn!, where(F!...), whereRaw with $N args, LIKE, contains)
  * are sent to PostgreSQL as bound parameters and never interpolated into the
  * SQL string. Each test attempts a classic injection and asserts that no
  * unintended rows are returned and that data is left intact.
  *
  * Sort columns: orderBy(string) is the one place a request parameter is
  * expected to land in the SQL text itself, since ORDER BY cannot be
  * parameterised. It admits column names only — a payload is refused before
  * anything reaches the server, and a quoted name is emitted between its
  * quotes, so it can name a column that does not exist but cannot end the
  * identifier.
  *
  * whereRaw(sqlFrag, ...) and orderByRaw(sql) take trusted SQL by contract and
  * are not covered here; see their doc comments.
  **/
module peque.orm.tests.security;

private import std.algorithm.searching: canFind;
private import std.exception: collectException;
private import std.process: environment;
private import peque.connection: Connection;
private import peque.exception: QueryClientError, QueryServerError;
private import peque.model: model, field, primaryKey, defaultOrder;
private import peque.orm;


// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

@model("peque_orm_sec_items")
struct SecItem {
    @primaryKey int    id;
    @field      string code;
    @field      string label;
}


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

private void setup(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS peque_orm_sec_items;
        CREATE TABLE peque_orm_sec_items (
            id    serial PRIMARY KEY,
            code  varchar(40) NOT NULL,
            label varchar(200) NOT NULL
        );
        INSERT INTO peque_orm_sec_items (code, label) VALUES
            ('t1', 'Target One'),
            ('t2', 'Target Two'),
            ('safe', 'Safe Row');
    `);
}

private auto repo(ref Connection c) {
    return Repository!(SecItem, Connection)(&c);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    // Classic tautology injected as a value must not return all rows.
    auto rows = r.query().where!"code"("' OR '1'='1").all();
    assert(rows.length == 0, "tautology injection via where! returned rows");

    // Comment-truncation injection must not bypass the filter.
    rows = r.query().where!"code"("t1' --").all();
    assert(rows.length == 0, "comment injection via where! returned rows");

    // UNION-based injection must not leak extra rows.
    rows = r.query().where!"code"("x' UNION SELECT 1,2,3 --").all();
    assert(rows.length == 0, "UNION injection via where! returned rows");

    // All three legitimate rows must still be present (no DROP/DELETE side effect).
    assert(r.query().count() == 3, "row count changed after injection attempts");
}

unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    // F!(M, field) predicate path.
    auto rows = r.query().where(F!(SecItem, "code")("' OR '1'='1")).all();
    assert(rows.length == 0, "tautology injection via F! predicate returned rows");

    rows = r.query().where(F!(SecItem, "code")("t1' --")).all();
    assert(rows.length == 0, "comment injection via F! predicate returned rows");
}

unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    // whereIn — injection in each element of the value list.
    auto rows = r.query().whereIn!"code"(["' OR '1'='1", "x' UNION SELECT 1,2,3 --"]).all();
    assert(rows.length == 0, "injection via whereIn returned rows");

    // A legitimate value mixed with an injection must match only the legitimate one.
    rows = r.query().whereIn!"code"(["t1", "' OR '1'='1"]).all();
    assert(rows.length == 1 && rows[0].code == "t1",
        "whereIn with mixed legit/injection values returned wrong result");
}

unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    // LIKE — injection in the pattern value must not escape parameterization.
    auto rows = r.query().where(F!(SecItem, "label").like("' OR '1'='1")).all();
    assert(rows.length == 0, "injection via LIKE returned rows");

    // Verify a legitimate LIKE pattern still works correctly.
    rows = r.query().where(F!(SecItem, "label").like("Target%")).all();
    assert(rows.length == 2, "legitimate LIKE pattern returned unexpected count");
}

unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    // whereRaw with $N bound args — the arg value must be parameterized.
    auto rows = r.query().whereRaw("code = $1", "' OR '1'='1").all();
    assert(rows.length == 0, "injection via whereRaw bound arg returned rows");

    // Special characters in bound values must round-trip intact.
    auto messy = `Double" Quote, Single' Quote, Backslash\, Percent%, SQL-- comment`;
    r.query().whereRaw("code = $1", "safe").all(); // warmup

    // Insert a row with messy label via the ORM, then read it back.
    auto tmp = SecItem(0, "messy", messy);
    auto inserted = r.insert(tmp);
    auto fetched  = r.query().where!"code"("messy").all();
    assert(fetched.length == 1 && fetched[0].label == messy,
        "special characters in bound value did not round-trip correctly");
}


// ---------------------------------------------------------------------------
// Sort columns: orderBy(string) is column names only
// ---------------------------------------------------------------------------

/// Every shape an attacker would try in a sort parameter is refused by the
/// grammar, client-side, naming the trusted hatch — and nothing ran.
unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    foreach (payload; [
        "code; DROP TABLE peque_orm_sec_items",
        "code; DROP TABLE peque_orm_sec_items; --",
        "code -- comment",
        "code /* comment */",
        "(SELECT 1)",
        "code, pg_sleep(5)",
        "code DESC, random()",
        "lower(code)",
        "CASE WHEN (SELECT 1)=1 THEN code END",
        "$$code$$",
        "1",
        "code DESC LIMIT 1",
        "code\0; DROP TABLE peque_orm_sec_items",
        "pg_catalog.pg_shadow.passwd",            // two dots: not a column name
        `code" DESC`,
        `"code"" ; DROP TABLE peque_orm_sec_items; --"`,
        `"x\"; DROP TABLE peque_orm_sec_items; --"`,   // a backslash does not escape a quote
    ]) {
        auto ex = collectException!QueryClientError(r.query().orderBy(payload));
        assert(ex !is null, "accepted: " ~ payload);
        assert(ex.msg.canFind("orderByRaw"), ex.msg);
    }
    assert(r.query().count() == 3, "row count changed after sort-column injection attempts");
}

/// A quoted name may hold anything but a quote, and is emitted between its
/// quotes: the server sees one identifier, which does not exist, and the
/// statement fails as a whole without running any of the payload.
unittest {
    auto c = makeConn();
    setup(c);
    auto r = c.repo;

    foreach (payload; [
        `"x; DROP TABLE peque_orm_sec_items; --"`,
        "\"x\n; DROP TABLE peque_orm_sec_items; --\"",
        `"pg_shadow"."passwd"`,                    // a table the query never joined
    ]) {
        auto ex = collectException!QueryServerError(r.query().orderBy(payload).all());
        assert(ex !is null, "did not reach the server as one bad identifier: " ~ payload);
        assert(ex.sqlstate == "42703" || ex.sqlstate == "42P01", payload ~ ": " ~ ex.sqlstate);
    }
    assert(r.query().count() == 3, "row count changed after quoted-identifier attempts");

    // The same grammar lets a legitimate sort parameter through, qualified so a
    // later join cannot make it ambiguous.
    auto rows = r.query().orderBy("code DESC").all();
    assert(rows.length == 3 && rows[0].code == "t2");
    assert(r.query().orderBy(`"code" DESC NULLS LAST, id`).all()[0].code == "t2");
}

// A @defaultOrder string is held to the same grammar, at compile time.
@model("peque_orm_sec_items")
@defaultOrder!("code; DROP TABLE peque_orm_sec_items")
struct SecDefaultOrderPayload {
    @primaryKey int id;
    @field      string code;
}
unittest {
    static assert(!__traits(compiles, {
        Connection c;
        auto r = Repository!(SecDefaultOrderPayload, Connection)(&c);
        r.query().all();
    }), "an expression in @defaultOrder must be refused at compile time");
}
