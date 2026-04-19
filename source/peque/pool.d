module peque.pool;

private import core.sync.semaphore: CoreSemaphore = Semaphore;
private import core.sync.mutex: Mutex;

private import peque.connection: Connection;
private import peque.lib.libpq: CONNECTION_OK;


/** Thin wrapper around core.sync.semaphore.Semaphore that exposes lock()/unlock()
  * so ThreadConnectionPool's Sem template parameter has the same interface as
  * vibe.d's LocalTaskSemaphore (which also uses lock/unlock names).
  **/
private final class ThreadSemaphore {
    private CoreSemaphore _sem;

    this(uint count) { _sem = new CoreSemaphore(count); }

    /// Acquire one slot (blocks the OS thread if count is 0).
    void lock() { _sem.wait(); }

    /// Release one slot, unblocking one waiter.
    void unlock() { _sem.notify(); }
}


/** Generic connection pool, templated on synchronization primitives.
  *
  * Sem must be a class exposing:
  *   - this(uint initialCount) — counting semaphore constructor
  *   - lock()   — decrement count; block (or yield in vibe.d) if count is 0
  *   - unlock() — increment count, unblocking one waiter
  *
  * Mtx must be a class exposing:
  *   - lock()   — acquire the mutex
  *   - unlock() — release the mutex
  *
  * Both core.sync.mutex.Mutex, vibe.d's LocalTaskSemaphore, and vibe.d's
  * TaskMutex satisfy these interfaces — the same pool template works in both
  * OS-thread and vibe.d fiber contexts.
  *
  * Pool is non-copyable. Allocate on the heap or own via pointer/reference.
  **/
struct ConnectionPool(Sem, Mtx) {
    private Connection[]           _conns;
    private bool[]                 _free;
    private Sem                    _sem;
    private Mtx                    _mtx;
    private Connection delegate()  _factory;

    @disable this();
    @disable this(this);
    @disable void opAssign(typeof(this));

    /** Construct a pool with fixed capacity.
      *
      * All connections are created eagerly via factory. If factory throws,
      * the pool is left partially constructed and must not be used.
      *
      * Params:
      *     capacity = maximum simultaneous connections (>= 1)
      *     factory  = delegate returning a fresh, connected Connection
      **/
    this(in size_t capacity, Connection delegate() factory)
    in (capacity >= 1, "Pool capacity must be at least 1") {
        _factory      = factory;
        _sem          = new Sem(cast(uint) capacity);
        _mtx          = new Mtx();
        _conns.length = capacity;
        _free.length  = capacity;
        foreach (i; 0 .. capacity) {
            _conns[i] = factory();
            _free[i]  = true;
        }
    }

    /** Borrow a connection and call fun with it.
      *
      * Blocks (or yields in vibe.d) until a slot is free, then calls
      * fun(ref conn). The connection is returned to the pool when fun
      * returns or throws — even if an exception propagates.
      *
      * A health check runs before calling fun: if the connection's status
      * is not CONNECTION_OK it is replaced by a fresh one from the factory.
      *
      * Params:
      *     fun = callable accepting (ref Connection); may return any type
      * Returns: whatever fun returns (void allowed)
      **/
    auto borrow(Fun)(Fun fun) {
        _sem.lock();
        scope(exit) _sem.unlock();

        immutable idx = _acquireSlot();
        scope(exit) _releaseSlot(idx);

        _healthCheck(idx);

        return fun(_conns[idx]);
    }

    /// Total number of connections managed by this pool.
    size_t capacity() const { return _conns.length; }

    // --- internals ---

    private size_t _acquireSlot() {
        _mtx.lock();
        scope(exit) _mtx.unlock();
        foreach (i; 0 .. _free.length) {
            if (_free[i]) {
                _free[i] = false;
                return i;
            }
        }
        assert(false,
            "Pool invariant violated: semaphore granted entry but no free slot found");
    }

    private void _releaseSlot(size_t idx) {
        _mtx.lock();
        scope(exit) _mtx.unlock();
        _free[idx] = true;
    }

    private void _healthCheck(size_t idx) {
        if (_conns[idx].status != CONNECTION_OK)
            _conns[idx] = _factory();
    }
}


/** Thread-safe connection pool for OS-thread workloads.
  *
  * Uses core.sync primitives — blocks the OS thread when the pool is exhausted.
  * For vibe.d fiber workloads, use VibeConnectionPool from peque:vibe instead.
  *
  * Example:
  * ---
  * auto pool = ThreadConnectionPool(4, () => Connection(
  *     dbname: "mydb", user: "app", password: "secret",
  *     host: "localhost", port: "5432"));
  *
  * auto rows = pool.borrow((ref Connection conn) => conn.exec("SELECT now()"));
  * ---
  **/
alias ThreadConnectionPool = ConnectionPool!(ThreadSemaphore, Mutex);
