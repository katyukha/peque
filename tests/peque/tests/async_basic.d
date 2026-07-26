/** Tests for the async query path — WaitStrategy plumbing and result correctness.
  *
  * All queries use the async path (PQsendQuery* + flush/consume loop), so
  * existing tests in other files verify query correctness on the default
  * (blocking) wait strategy.  These tests add two contracts:
  *
  *  1. Infrastructure: waitReadable is invoked at least once per query when
  *     a MockWS is in use — confirms the async loop is actually reached.
  *  2. Correctness: results returned through the async path are accurate —
  *     correct values, correct row counts, no cross-query contamination.
  **/
module peque.tests.async_basic;

private import std.process: environment;
private import std.exception: assertThrown, collectException;
private import peque.connection: Connection;
private import peque.exception: QueryError;
private import peque.wait_strategy: MockWaitStrategy, MockWS;


private Connection mockConn(ref MockWaitStrategy mock) {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
        MockWS(&mock),
    );
}


// ---------------------------------------------------------------------------
// Infrastructure: waitReadable is called for every query
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    auto before = mock.readableCount;
    c.exec("SELECT 1");
    assert(mock.readableCount > before,
        "waitReadable must be called at least once per exec()");

    before = mock.readableCount;
    c.execParams("SELECT $1::int", 42);
    assert(mock.readableCount > before,
        "waitReadable must be called at least once per execParams()");
}

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    immutable n = 10;
    foreach (_; 0 .. n)
        c.exec("SELECT 1");

    assert(mock.readableCount >= n,
        "readableCount must accumulate across queries");
}


// ---------------------------------------------------------------------------
// Correctness: exec returns accurate results through the async path
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    auto res = c.exec("SELECT 1 + 1");
    assert(res.ntuples == 1);
    assert(res[0][0].as!int == 2, "async exec must return the correct computed value");
}

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    // Multiple rows — correct count and values.
    auto res = c.exec("SELECT v FROM generate_series(1, 5) v ORDER BY v");
    assert(res.ntuples == 5, "async exec must return all rows");
    foreach (i; 0 .. 5)
        assert(res[i][0].as!int == i + 1,
            "row values must be correct through async path");
}


// ---------------------------------------------------------------------------
// Correctness: execParams binds values correctly through the async path
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    // Bound parameter must reach PostgreSQL intact.
    auto res = c.execParams("SELECT $1::text", "hello async");
    assert(res.ntuples == 1);
    assert(res[0][0].as!string == "hello async",
        "execParams bound value must round-trip correctly through async path");
}

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    // Multiple parameters, multiple rows — no mix-up between queries.
    auto r1 = c.execParams("SELECT $1::int + $2::int", 3, 4);
    auto r2 = c.execParams("SELECT $1::int * $2::int", 3, 4);
    assert(r1[0][0].as!int == 7,  "first query result must not be contaminated by second");
    assert(r2[0][0].as!int == 12, "second query result must not be contaminated by first");
}


// ---------------------------------------------------------------------------
// Error propagation: bad SQL raises QueryError through the async path
// ---------------------------------------------------------------------------

// The async loop (send → flush → waitReadable → consumeInput → collectResult)
// must propagate errors correctly; errors must not be silently swallowed.
unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    auto ex = collectException!QueryError(c.exec("SELECT * FROM no_such_table_xyz"));
    assert(ex !is null, "malformed/invalid query must raise QueryError");

    // Constraint violation through execParams must also raise QueryError.
    c.exec(`
        DROP TABLE IF EXISTS peque_async_err_test;
        CREATE TABLE peque_async_err_test (id int PRIMARY KEY);
        INSERT INTO peque_async_err_test VALUES (1);
    `);
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_async_err_test");

    auto ex2 = collectException!QueryError(
        c.execParams("INSERT INTO peque_async_err_test VALUES ($1)", 1));
    assert(ex2 !is null, "unique constraint violation must raise QueryError");

    // Connection must still be usable after an error.
    auto res = c.execParams("SELECT $1::int", 99);
    assert(res[0][0].as!int == 99, "connection must be usable after a query error");
}


// ---------------------------------------------------------------------------
// Multi-statement exec: last result is returned, earlier ones discarded
// ---------------------------------------------------------------------------

// exec() passes the string to PQsendQuery which can produce multiple results.
// _collectResult must return the last one and PQclear the rest.
unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    // Two statements: only the second result should be returned.
    auto res = c.exec("SELECT 1; SELECT 2");
    assert(res.ntuples == 1);
    assert(res[0][0].as!int == 2,
        "exec with multiple statements must return the last result");

    // Three statements — still only the last.
    auto res2 = c.exec("SELECT 10; SELECT 20; SELECT 30");
    assert(res2[0][0].as!int == 30,
        "exec with three statements must return the last result");
}


// ---------------------------------------------------------------------------
// PreparedStatement: uses the same async path, waitReadable must be called
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    auto ps = c.prepare("add_two_ints", "SELECT $1::int + $2::int");

    auto before = mock.readableCount;
    auto res = ps.exec(3, 7);
    assert(mock.readableCount > before,
        "PreparedStatement.exec must invoke waitReadable through the async path");
    assert(res[0][0].as!int == 10,
        "PreparedStatement result must be correct through async path");

    // Execute again — result must be independent of the first call.
    auto res2 = ps.exec(100, 200);
    assert(res2[0][0].as!int == 300,
        "second PreparedStatement execution must return its own correct result");
}


// ---------------------------------------------------------------------------
// Correctness: transactions work correctly through the async path
// ---------------------------------------------------------------------------

unittest {
    MockWaitStrategy mock;
    auto c = mockConn(mock);

    c.exec(`
        DROP TABLE IF EXISTS peque_async_tx_test;
        CREATE TABLE peque_async_tx_test (v int);
    `);
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_async_tx_test");

    // Committed transaction — row must be visible afterwards.
    c.transaction((ref tx) {
        tx.exec("INSERT INTO peque_async_tx_test VALUES (42)");
    });
    auto res = c.exec("SELECT v FROM peque_async_tx_test");
    assert(res.ntuples == 1 && res[0][0].as!int == 42,
        "committed transaction must persist through async path");

    // Rolled-back transaction — row must NOT be visible afterwards.
    try {
        c.transaction((ref tx) {
            tx.exec("INSERT INTO peque_async_tx_test VALUES (99)");
            throw new Exception("force rollback");
        });
    } catch (Exception) {}

    auto res2 = c.exec("SELECT v FROM peque_async_tx_test");
    assert(res2.ntuples == 1,
        "rolled-back insert must not persist through async path");
}
