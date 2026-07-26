/** COPY TO/FROM STDOUT|STDIN is not supported by peque — it must be rejected
  * with QueryError and leave the connection usable.
  *
  * Without explicit handling, libpq keeps returning fresh PGRES_COPY_*
  * results from PQgetResult until the COPY sub-protocol is performed, so the
  * result-collection loop would spin forever at 100% CPU.
  **/
module peque.tests.copy_reject;

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

private void assertUsable(ref Connection c) {
    assert(c.exec("SELECT 42").getValue(0, 0).get!int == 42,
        "connection must remain usable after a rejected COPY");
}

unittest {
    auto c = makeConn();

    // COPY OUT — server streams data at us
    c.exec("COPY (SELECT generate_series(1, 1000)) TO STDOUT")
        .assertThrown!QueryError;
    assertUsable(c);

    // COPY IN — server waits for data from us
    c.exec(`
        DROP TABLE IF EXISTS peque_copy_test;
        CREATE TABLE peque_copy_test(x int);
    `);
    c.exec("COPY peque_copy_test FROM STDIN").assertThrown!QueryError;
    assertUsable(c);

    // COPY in the middle of a multi-statement string — trailing statements
    // must be drained too
    c.exec("SELECT 1; COPY (SELECT 1) TO STDOUT; SELECT 2")
        .assertThrown!QueryError;
    assertUsable(c);

    // Two COPY statements in a row — the drain loop must not trip over the
    // second COPY result
    c.exec("COPY (SELECT 1) TO STDOUT; COPY (SELECT 2) TO STDOUT")
        .assertThrown!QueryError;
    assertUsable(c);

    // execMulti path uses a separate collection loop
    c.execMulti("SELECT 1; COPY (SELECT 1) TO STDOUT").assertThrown!QueryError;
    assertUsable(c);

    c.exec("DROP TABLE IF EXISTS peque_copy_test");
}
