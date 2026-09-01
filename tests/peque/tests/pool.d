/** Integration tests for ThreadConnectionPool.
  *
  * Covers: basic borrow, return value propagation, sequential borrows,
  * exception safety (connection returned even when fun throws), capacity
  * reporting, and health check (dead connection is replaced).
  **/
module peque.tests.pool;

private import std.process: environment;
private import std.exception: assertThrown, collectException;

private import core.sys.posix.sys.socket: shutdown, SHUT_RDWR;

private import peque.connection: Connection;
private import peque.pool: ThreadConnectionPool;
private import peque.exception: QueryError;


private Connection delegate() makeFactory() {
    return () => Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


/** Basic borrow: run a query and get a result back. **/
unittest {
    auto pool = ThreadConnectionPool(2, makeFactory());

    auto res = pool.borrow((ref Connection conn) => conn.exec("SELECT 42::int"));
    assert(res[0][0].get!int == 42);
}


/** Return value propagation: borrow can return any type. **/
unittest {
    auto pool = ThreadConnectionPool(1, makeFactory());

    string s = pool.borrow((ref Connection conn) {
        auto res = conn.execParams("SELECT $1::text", "hello");
        return res[0][0].get!string;
    });
    assert(s == "hello");
}


/** Sequential borrows: each borrow gets a working connection. **/
unittest {
    auto pool = ThreadConnectionPool(2, makeFactory());

    foreach (i; 0 .. 5) {
        auto res = pool.borrow((ref Connection conn) => conn.execParams("SELECT $1::int", i));
        assert(res[0][0].get!int == i);
    }
}


/** capacity() returns the value passed at construction. **/
unittest {
    auto pool = ThreadConnectionPool(3, makeFactory());
    assert(pool.capacity == 3);
}


/** Exception safety: if fun throws, the connection is still returned to the pool
  * and subsequent borrows work normally. **/
unittest {
    auto pool = ThreadConnectionPool(1, makeFactory());

    // First borrow throws a QueryError (bad SQL).
    auto ex = collectException!QueryError(
        pool.borrow((ref Connection conn) { conn.exec("NOT VALID SQL!!!"); }));
    assert(ex !is null, "expected QueryError from bad SQL");

    // Pool must be healthy — next borrow must succeed.
    auto res = pool.borrow((ref Connection conn) => conn.exec("SELECT 1"));
    assert(res[0][0].get!int == 1);
}


/** Exception safety: D exceptions also return the connection. **/
unittest {
    auto pool = ThreadConnectionPool(1, makeFactory());

    auto ex = collectException!Exception(
        pool.borrow((ref Connection conn) { throw new Exception("test error"); }));
    assert(ex !is null);
    assert(ex.msg == "test error");

    // Pool still works.
    auto res = pool.borrow((ref Connection conn) => conn.exec("SELECT 2"));
    assert(res[0][0].get!int == 2);
}


/** Post-use health check: a stale connection (socket closed mid-borrow) is
  * replaced before the slot is released so the next borrow gets a live
  * connection rather than inheriting the dead one. **/
unittest {
    auto pool = ThreadConnectionPool(1, makeFactory());

    // Shut down I/O on the socket without closing the fd.  This accurately
    // models a real stale TCP connection (NAT timeout / server-side idle
    // close): PQstatus still reports CONNECTION_OK (cached), but the next
    // I/O attempt fails.  Using shutdown rather than close avoids freeing
    // the fd number, so _factory() cannot accidentally reuse it.
    auto ex = collectException!Exception(pool.borrow((ref Connection conn) {
        shutdown(conn.socketFd(), SHUT_RDWR);
        conn.exec("SELECT 1"); // must fail — connection shut down
    }));
    assert(ex !is null, "expected an error after socket was closed");

    // Post-use check should have replaced the dead connection.
    // The next borrow must succeed with a fresh connection.
    auto res = pool.borrow((ref Connection conn) => conn.exec("SELECT 99"));
    assert(res[0][0].get!int == 99);
}


/** Range API works through a pool borrow (multi-row result iteration). **/
unittest {
    import std.algorithm: map;
    import std.array: array;

    auto pool = ThreadConnectionPool(1, makeFactory());

    auto codes = pool.borrow((ref Connection conn) {
        conn.exec("
            DROP TABLE IF EXISTS peque_pool_test;
            CREATE TABLE peque_pool_test (code varchar(5));
            INSERT INTO peque_pool_test VALUES ('a'), ('b'), ('c');
        ");
        scope(exit) conn.exec("DROP TABLE IF EXISTS peque_pool_test");
        auto res = conn.exec("SELECT code FROM peque_pool_test ORDER BY code");
        return res.map!((row) => row["code"].as!string).array;
    });
    assert(codes == ["a", "b", "c"]);
}


/** close() must be a safe no-op on a default-constructed (never-connected)
  * Connection — the state a pool slot is in when, under GC ownership, the
  * Connection's own destructor runs before the pool's ~this reaches it.
  * Touching the SafeRefCounted payload there is an AssertError. **/
unittest {
    Connection c;      // default-init: SafeRefCounted store is uninitialized
    c.close();         // must not throw
    c.close();         // idempotent
}


/** A GC-owned pool: ~ConnectionPool runs as a finalizer and closes each slot.
  * With close() safe on a finalized slot, teardown under the GC is safe. This
  * mirrors a web-framework TestClient that stores the pool in a GC object and
  * churns create/destroy across many requests. **/
unittest {
    import core.memory: GC;
    foreach (cycle; 0 .. 12) {
        auto poolPtr = new ThreadConnectionPool(2, makeFactory());
        poolPtr.borrow((ref Connection conn) => conn.exec("SELECT 1"));
        poolPtr = null;   // drop the only root
        GC.collect();     // finalize the pool + its connections
    }
}


// ---------------------------------------------------------------------------
// Contention under OS threads: more threads than connections — excess
// threads block on the semaphore, at most `capacity` borrows run at once,
// and every thread completes.
// ---------------------------------------------------------------------------
unittest {
    import core.thread: Thread;
    import core.atomic: atomicOp, atomicLoad;

    auto pool = ThreadConnectionPool(2, makeFactory());
    shared int active = 0;
    shared int done = 0;

    Thread[] threads;
    foreach (i; 0 .. 6)
        threads ~= new Thread({
            pool.borrow((ref Connection c) {
                immutable now = atomicOp!"+="(active, 1);
                assert(now <= 2, "more concurrent borrows than pool capacity");
                c.exec("SELECT pg_sleep(0.05)");
                atomicOp!"-="(active, 1);
            });
            atomicOp!"+="(done, 1);
        }).start();

    foreach (t; threads)
        t.join();   // rethrows any in-thread failure, including asserts

    assert(atomicLoad(done) == 6);
    assert(atomicLoad(active) == 0);
    pool.close();
}
