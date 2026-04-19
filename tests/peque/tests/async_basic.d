/** Tests for the async query path — specifically the WaitStrategy plumbing.
  *
  * All queries already use the async path (PQsendQuery* + flush/consume loop),
  * so existing tests exercise correctness. These tests focus on the additional
  * observable property: that waitReadable (and occasionally waitWritable) is
  * called at least once per query when a MockWS is in use.
  **/
module peque.tests.async_basic;

private import std.process: environment;

private import peque.connection: Connection;
private import peque.wait_strategy: MockWaitStrategy, MockWS;


/** Connect with MockWS so we can inspect waitReadable/waitWritable call counts. **/
unittest {
    MockWaitStrategy mock;
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
        MockWS(&mock),
    );

    // Each query must wait for at least one readable event.
    auto before = mock.readableCount;
    c.exec("SELECT 1");
    assert(mock.readableCount > before,
        "waitReadable should be called at least once per exec()");

    before = mock.readableCount;
    c.execParams("SELECT $1::int", 42);
    assert(mock.readableCount > before,
        "waitReadable should be called at least once per execParams()");
}

/** Verify counter accumulates over multiple queries. **/
unittest {
    MockWaitStrategy mock;
    auto c = Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
        MockWS(&mock),
    );

    immutable n = 10;
    foreach (_; 0 .. n)
        c.exec("SELECT 1");

    assert(mock.readableCount >= n,
        "readableCount must be >= number of queries");
}
