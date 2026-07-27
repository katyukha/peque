/** VibeConnectionPool and makeVibePool factory.
  **/
module peque.vibe.pool;

private import vibe.core.sync: LocalTaskSemaphore, TaskMutex;

private import peque.connection: Connection;
private import peque.pool: ConnectionPool;
private import peque.vibe.wait_strategy: VibeWaitStrategy;


/** Fiber-aware connection pool for vibe.d applications.
  *
  * When the pool is exhausted, borrow() yields the calling fiber
  * (via LocalTaskSemaphore.lock) until a connection is returned,
  * allowing other vibe.d tasks to run in the meantime.
  *
  * Must be used from within a vibe.d task (fiber) context.
  **/
alias VibeConnectionPool = ConnectionPool!(LocalTaskSemaphore, TaskMutex);


/** Convenience factory: create a VibeConnectionPool from connection parameters.
  *
  * Each connection is created with VibeWaitStrategy and set to non-blocking
  * mode (required so PQflush returns 1 — would block — rather than blocking
  * the event thread when the OS send buffer is full).
  *
  * Params:
  *     capacity = number of connections to pre-create (>= 1)
  *     params   = connection keyword arguments (dbname, user, password, host, port, …)
  * Returns: VibeConnectionPool ready for use inside vibe.d tasks
  *
  * Example:
  * ---
  * auto pool = makeVibePool(8, [
  *     "dbname": "myapp",
  *     "user":   "app",
  *     "host":   "localhost",
  *     "port":   "5432",
  * ]);
  * ---
  **/
VibeConnectionPool makeVibePool(in size_t capacity, in string[string] params) {
    return VibeConnectionPool(capacity, () {
        auto conn = Connection(params.dup, VibeWaitStrategy());
        conn.setNonBlocking(true);
        return conn;
    });
}

/// ditto — factory delegate overload for callers that need custom connection logic.
VibeConnectionPool makeVibePool(in size_t capacity, Connection delegate() factory) {
    return VibeConnectionPool(capacity, () {
        auto conn = factory();
        conn.setNonBlocking(true);
        return conn;
    });
}
