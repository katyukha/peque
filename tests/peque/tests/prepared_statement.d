/** Integration tests for Connection.prepare() and PreparedStatement.
  *
  * Covers: prepare + exec (no params), prepare + exec (with params),
  * repeated executions, pg_prepared_statements visibility, destructor
  * DEALLOCATE, and rejection of invalid statement names.
  **/
module peque.tests.prepared_statement;

private import std.process: environment;
private import std.exception: assertThrown;

private import peque.connection: Connection;
private import peque.exception: QueryError;


private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


/** Prepare a statement and execute it without parameters. **/
unittest {
    auto c = makeConn();
    auto stmt = c.prepare("ps_no_params", "SELECT 42");
    auto res = stmt.exec();
    assert(res[0][0].get!int == 42);
}

/** Prepare a statement and execute it with parameters. **/
unittest {
    auto c = makeConn();
    auto stmt = c.prepare("ps_with_params", "SELECT $1::int + $2::int");
    auto res = stmt.exec(10, 32);
    assert(res[0][0].get!int == 42);
}

/** Execute the same prepared statement multiple times. **/
unittest {
    auto c = makeConn();
    auto stmt = c.prepare("ps_repeated", "SELECT $1::text");

    foreach (s; ["foo", "bar", "baz"]) {
        auto res = stmt.exec(s);
        assert(res[0][0].get!string == s);
    }
}

/** Statement should appear in pg_prepared_statements while handle is alive. **/
unittest {
    auto c = makeConn();
    {
        auto stmt = c.prepare("ps_visibility", "SELECT 1");

        auto res = c.execParams(
            "SELECT count(*) FROM pg_prepared_statements WHERE name = $1",
            "ps_visibility");
        assert(res[0][0].get!long == 1, "statement must be visible while handle is alive");
    }
    // After handle goes out of scope, DEALLOCATE should have been issued.
    auto res = c.execParams(
        "SELECT count(*) FROM pg_prepared_statements WHERE name = $1",
        "ps_visibility");
    assert(res[0][0].get!long == 0, "statement must be gone after handle destruction");
}

/** Preparing with an invalid name must throw QueryError before sending to server. **/
unittest {
    auto c = makeConn();

    assertThrown!QueryError(c.prepare("123bad",   "SELECT 1"));
    assertThrown!QueryError(c.prepare("bad-name", "SELECT 1"));
    assertThrown!QueryError(c.prepare("",         "SELECT 1"));
    assertThrown!QueryError(c.prepare("has space", "SELECT 1"));
}

/** Parameters passed to PreparedStatement.exec() are parameterized — no injection. **/
unittest {
    auto c = makeConn();

    c.exec("
        DROP TABLE IF EXISTS peque_ps_injection;
        CREATE TABLE peque_ps_injection (v text);
        INSERT INTO peque_ps_injection VALUES ('safe');
    ");
    scope(exit) c.exec("DROP TABLE IF EXISTS peque_ps_injection");

    auto stmt = c.prepare("ps_inj", "SELECT count(*) FROM peque_ps_injection WHERE v = $1");

    // A naive injection attempt is treated as a literal string → returns 0 rows
    auto res = stmt.exec("safe' OR '1'='1");
    assert(res[0][0].get!long == 0);

    // The actual value still matches
    res = stmt.exec("safe");
    assert(res[0][0].get!long == 1);
}
