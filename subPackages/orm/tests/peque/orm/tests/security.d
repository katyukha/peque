/** SQL-injection safety tests for peque:orm predicates.
  *
  * Verifies that injection payloads passed as predicate *values* through the
  * ORM (where!, whereIn!, where(F!...), whereRaw with $N args, LIKE, contains)
  * are sent to PostgreSQL as bound parameters and never interpolated into the
  * SQL string.  Each test attempts a classic injection and asserts that no
  * unintended rows are returned and that data is left intact.
  *
  * Note: orderBy() and whereRaw(sqlFrag, ...) accept developer-controlled SQL
  * fragments directly — they are not covered here.  See their doc comments for
  * the security contract.
  **/
module peque.orm.tests.security;

private import std.process: environment;
private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
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
