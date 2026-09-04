module peque.pool;

private import core.sync.semaphore: CoreSemaphore = Semaphore;
private import core.sync.mutex: Mutex;

private import peque.connection: Connection;
private import peque.lib.libpq: CONNECTION_OK, PQTRANS_IDLE;
private import peque.exception: QueryClientError;


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

    ~this() nothrow { try { close(); } catch (Exception) {} }

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
      * A pre-use health check replaces the connection if its cached status
      * is not CONNECTION_OK. A post-use health check additionally replaces
      * connections that went dead during the call (e.g. server-side idle
      * timeout that closed the TCP socket while PQstatus still reported OK).
      * The post-use check is best-effort: if the factory throws, the broken
      * connection is left in the slot and the next borrower's pre-use check
      * will retry, so the pool never deadlocks.
      *
      * Params:
      *     fun = callable accepting (ref Connection); may return any type
      * Returns: whatever fun returns (void allowed)
      **/
    auto borrow(Fun)(Fun fun) {
        _sem.lock();
        scope(exit) _sem.unlock();

        immutable idx = _acquireSlot();
        // Scope guards execute LIFO.
        // Order: failure-flag → reclaim → replace → release.
        scope(exit) _releaseSlot(idx);
        bool _connOk = true;
        scope(exit) {
            if (!_connOk || _conns[idx].status != CONNECTION_OK)
                _replaceBrokenSafe(idx);
        }
        scope(exit) _reclaimSlot(idx, _connOk);
        // Mark connection suspect whenever fun exits via exception —
        // even when PQstatus still caches CONNECTION_OK (stale TCP socket).
        scope(failure) _connOk = false;

        _healthCheck(idx);

        return fun(_conns[idx]);
    }

    /// Total number of connections managed by this pool.
    size_t capacity() const { return _conns.length; }

    /** Close all connections immediately.
      *
      * Call this before exiting the event loop (e.g. in a SIGINT handler)
      * to release file descriptors before the I/O driver tears down.
      * The pool must not be borrowed from after close() is called.
      **/
    void close() {
        foreach (ref conn; _conns)
            conn.close();
    }

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
        if (_conns[idx].status != CONNECTION_OK) {
            _conns[idx] = _factory();
            return;
        }
        // A slot should never arrive dirty — _reclaimSlot cleans it before
        // release — but reset quietly rather than hand on someone else's
        // transaction. No caller to blame at this point.
        if (_hasOpenTransaction(idx) && !_rollbackSafe(idx))
            _conns[idx] = _factory();
    }

    /** Roll back a transaction the borrow left open, and do not hide the leak.
      *
      * The rollback DISCARDS the borrow's writes, so reporting it matters: a
      * silent one would lose data with no signal. When fun threw, the
      * transaction was being abandoned anyway — stay quiet so the caller's
      * exception propagates unchained. Clearing connOk on a failed rollback
      * lets the outer guard replace a connection that cannot be cleaned.
      **/
    private void _reclaimSlot(size_t idx, ref bool connOk) {
        if (!_hasOpenTransaction(idx)) return;
        immutable borrowSucceeded = connOk;
        if (!_rollbackSafe(idx)) { connOk = false; return; }
        if (borrowSucceeded)
            throw new QueryClientError(
                "A pooled connection was returned with a transaction still " ~
                "open, so the pool rolled it back — every write it made is " ~
                "gone. Something in the borrow ran BEGIN without a matching " ~
                "COMMIT or ROLLBACK; use conn.transaction(), which does both " ~
                "for you.");
    }

    private bool _hasOpenTransaction(size_t idx) nothrow {
        try { return _conns[idx].transactionStatus != PQTRANS_IDLE; }
        catch (Exception) { return false; }
    }

    /// False when the rollback could not be sent at all.
    private bool _rollbackSafe(size_t idx) nothrow {
        try { _conns[idx].exec("ROLLBACK"); return true; }
        catch (Exception) { return false; }
    }

    // D forbids catch inside scope(exit), so this nothrow wrapper replaces
    // a broken connection and swallows factory errors so the slot is always
    // released.  If the factory fails, the broken connection (CONNECTION_BAD)
    // stays in the slot; _healthCheck on the next borrow will retry.
    private void _replaceBrokenSafe(size_t idx) nothrow {
        try { _conns[idx] = _factory(); } catch (Exception) {}
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
