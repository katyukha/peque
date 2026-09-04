module peque.connection;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind, map;
private import std.array: array;
private import core.time: Duration;

private import versioned: Version;

private import peque.lib;
private import peque.exception;
private import peque.pg_type;
private import peque.pg_format;
private import peque.result;
private import peque.wait_strategy;
private import peque.converter: PGValue, convertToPG;


/** Controls what happens at the end of a successful transaction() call.
  *
  * On failure (exception) the transaction is always rolled back regardless
  * of this setting.
  **/
enum OnSuccess {
    commit,   /// Commit the transaction (default).
    rollback, /// Roll back even on success — useful for dry-runs and tests.
}


/** Transaction isolation level passed to Connection.transaction().
  *
  * Maps directly to PostgreSQL isolation levels. The default template parameter
  * value is readCommitted, which is the PostgreSQL built-in default.
  *
  * Use serverDefault to emit a plain BEGIN with no ISOLATION LEVEL clause,
  * deferring to whatever the server, role, or database has been configured with
  * (postgresql.conf / ALTER ROLE / ALTER DATABASE).
  *
  * Note: PostgreSQL does not implement readUncommitted — it is omitted here.
  **/
enum IsolationLevel {
    readCommitted,  /// Each statement sees a fresh snapshot of committed data (PostgreSQL built-in default).
    repeatableRead, /// Entire transaction sees a snapshot taken at the first statement.
    serializable,   /// Full serializability; may abort with a serialization failure that must be retried.
    serverDefault,  /// Defer to the server/role/database configured default — emits plain BEGIN.
}


/** Type-erased pair of wait delegates stored in every Connection.
  *
  * Set once at construction from a WaitStrategy value; never mutated afterwards.
  * Read-only during query dispatch — trivially thread-safe without atomics.
  *
  * The first slot is required (isWaitStrategy).  The second is optional: it
  * is null when the strategy does not provide the timed
  * `bool wait(int fd, WaitMask, Duration)` overload (hasTimedWait), and only
  * waitNotifications depends on it.
  **/
private struct RuntimeWaitStrategy {
    void delegate(int fd, WaitMask mask) @safe wait;
    /// Optional timed wait; null when the strategy lacks the timed overload.
    bool delegate(int fd, WaitMask mask, Duration timeout) @safe waitTimed;
}


/** A NOTIFY message received from the server on a LISTENed channel.
  *
  * All strings are GC-owned copies — safe to retain after the call that
  * produced them (the underlying libpq memory is released immediately).
  **/
struct Notification {
    string channel;    /// channel name the notification was sent on
    string payload;    /// payload string (empty when NOTIFY had no payload)
    int backendPid;    /// PID of the notifying server backend
}


/// Connection to PostgreSQL database.
struct Connection {

    /// Wrapper for PGconn to be used for ConnectionInternal refcounted struct
    private struct ConnectionInternalData {
        PGconn* _pg_conn;

        this(in string conn_info) @trusted {
            _pg_conn = PQconnectdb(conn_info.toStringz);
        }

        this(in string[] keywords, in string[] values) @trusted {
            auto _res_keywords = keywords.map!(i => i.toStringz).array ~ [cast(immutable(char)*)null];
            auto _res_values = values.map!(i => i.toStringz).array ~ [cast(immutable(char)*)null];
            _pg_conn = PQconnectdbParams(_res_keywords.ptr, _res_values.ptr, 0);
        }

        this(in string[string] params) {
            string[] keywords;
            string[] values;
            foreach(kv; params.byKeyValue) {
                keywords ~= kv.key;
                values ~= kv.value;
            }
            this(keywords, values);
        }

        void close() @trusted nothrow @nogc {
            if (_pg_conn !is null) {
                PQfinish(_pg_conn);
                _pg_conn = null;
            }
        }

        ~this() @trusted nothrow @nogc { close(); }

        // Must not be copiable — opAssign is intentionally left enabled so that
        // SafeRefCounted can move-initialise the payload via std.algorithm.mutation.move.
        // move() resets the source to T.init (null pointer) before the destructor runs,
        // so there is no double-free risk.
        @disable this(this);
    }

    /// Ref-counted connection to postgres
    package(peque) alias SafeRefCounted!(
        ConnectionInternalData,
        RefCountedAutoInitialize.no,
    ) ConnectionInternal;


    package(peque) ConnectionInternal _connection;
    private RuntimeWaitStrategy _asyncHooks;

    /** Construct from a connection string. WaitStrategy defaults to PollWaitStrategy.
      *
      * `timezone` pins the session TimeZone (empty leaves it to the server).
      * A custom WaitStrategy comes last, so name it when the zone is omitted:
      * ---
      * // vibe.d pool factory:
      * auto conn = Connection(connStr, ws: VibeWaitStrategy());
      *
      * // Tests:
      * MockWaitStrategy mock;
      * auto conn = Connection(connStr, ws: MockWS(&mock));
      * ---
      **/
    this(WS = PollWaitStrategy)(in string conn_info, in string timezone = "",
            WS ws = WS.init)
            if (isWaitStrategy!WS) {
        _connection = ConnectionInternal(conn_info);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
        _setHooks(ws);

        if (timezone.length > 0) _applySessionTimezone(timezone);
    }

    /** ditto
      *
      * `params` reaches libpq untouched: every entry is a libpq keyword, and
      * libpq rejects any it does not recognise. peque's own settings, such as
      * `timezone`, are separate parameters for that reason.
      **/
    this(WS = PollWaitStrategy)(in string[string] params, in string timezone = "",
            WS ws = WS.init)
            if (isWaitStrategy!WS) {
        _connection = ConnectionInternal(params);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
        _setHooks(ws);

        if (timezone.length > 0) _applySessionTimezone(timezone);
    }

    /** ditto
      *
      * Params:
      *     timezone = session `TimeZone` to pin, e.g. "UTC" or "Europe/Kyiv".
      *         Empty (the default) leaves it to the server's configuration or
      *         `PGTZ`. It governs what the SERVER renders (`now()::text`,
      *         `to_char`, a `timestamptz` cast to text) — never the meaning of a
      *         value peque sends or reads, which is session-independent by
      *         construction. Applied once, at connect.
      **/
    // `timezone` precedes `ws` because a named argument cannot skip a
    // template-typed parameter: reversed, `timezone: "UTC"` binds to `ws` and
    // fails to compile. A positional `ws` must therefore be named `ws:`.
    this(WS = PollWaitStrategy)(in string dbname, in string user, in string password,
            in string host, in string port, in string timezone = "",
            WS ws = WS.init)
            if (isWaitStrategy!WS) {
        string[string] p;
        if (dbname && dbname.length > 0)   p["dbname"]   = dbname.dup;
        if (user && user.length > 0)       p["user"]     = user.dup;
        if (password && password.length > 0) p["password"] = password.dup;
        if (host && host.length > 0)       p["host"]     = host.dup;
        if (port && port.length > 0)       p["port"]     = port.dup;
        this(p, timezone, ws);
    }

    /** Pin this session's TimeZone, once, at connect time.
      *
      * Governs what the SERVER renders (`now()::text`, `to_char`, a timestamptz
      * cast to text) — never the meaning of a value peque sends or reads, which
      * is session-independent by construction.
      *
      * Uses `set_config()` because `SET TIME ZONE` takes no placeholders and the
      * zone would otherwise have to be escaped into the statement text.
      *
      * Connect-time only: a pooled connection keeps session state across
      * borrows, so setting the zone per request would leak it into the next
      * borrower. For a per-user zone, convert at the edges or say
      * `AT TIME ZONE $1` in the query.
      **/
    private void _applySessionTimezone(in string tz) {
        try
            execParams(`SELECT set_config('TimeZone', $1, false)`, tz);
        catch (QueryError e)
            throw new ConnectionError(
                "Cannot set session timezone to '" ~ tz ~ "': " ~ e.msg, e);
    }

    private void _setHooks(WS)(WS ws) if (isWaitStrategy!WS) {
        _asyncHooks.wait = (int fd, WaitMask mask) @trusted { ws.wait(fd, mask); };
        static if (hasTimedWait!WS)
            _asyncHooks.waitTimed =
                (int fd, WaitMask mask, Duration timeout) @trusted
                    => ws.wait(fd, mask, timeout);
    }

    auto serverVersion() {
        int v = _connection.borrow!((auto ref conn) @trusted => PQserverVersion(conn._pg_conn));
        return _parseServerVersion(v);
    }

    /** Decode a PQserverVersion() value.
      *
      * Since PostgreSQL 10 versions are two-part: major * 10000 + minor.
      * Before 10 they were three-part: major * 10000 + minor * 100 + patch.
      * See https://www.postgresql.org/docs/current/libpq-status.html#LIBPQ-PQSERVERVERSION
      **/
    package(peque) static Version _parseServerVersion(int v) @safe pure nothrow {
        immutable major = v / 10000;
        immutable rest  = v % 10000;
        if (major >= 10)
            return Version(major, rest);
        return Version(major, rest / 100, rest % 100);
    }

    /// Check status of connection
    auto status() { return _connection.borrow!((auto ref conn) @trusted => PQstatus(conn._pg_conn)); }

    /** The connection's transaction state — one of the PQTRANS_* values.
      *
      * `PQTRANS_INTRANS` and `PQTRANS_INERROR` both mean a transaction block is
      * open; `INERROR` additionally means it has already failed and the server
      * will accept nothing but ROLLBACK. Read from libpq's own protocol state,
      * so it also sees a transaction opened by a bare `exec("BEGIN")`.
      **/
    auto transactionStatus() {
        return _connection.borrow!(
            (auto ref conn) @trusted => PQtransactionStatus(conn._pg_conn));
    }

    /// Return most recent error message
    auto errorMessage() {
        return _connection.borrow!((auto ref conn) @trusted {
            return PQerrorMessage(conn._pg_conn).fromStringz.idup;
        });
    }

    /// Switch connection to non-blocking libpq mode.
    /// Required by vibe.d pool factory so PQflush returns 1 (would block)
    /// rather than briefly blocking the event thread.
    void setNonBlocking(bool nb) @trusted {
        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsetnonblocking(conn._pg_conn, nb ? 1 : 0) == 0,
                "PQsetnonblocking failed: " ~ errorMessage);
        });
    }

    /// Return whether the connection is in non-blocking mode.
    bool isNonBlocking() @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            return PQisnonblocking(conn._pg_conn) != 0;
        });
    }

    /** Escape value as postgresql string
      *
      * Params:
      *     value = string value to escape
      * Returns:
      *     Escaped string value, but without surrounding single quotes.
      **/
    string escapeString(in string value) {
        enforce!QueryEscapingError(
            !value.canFind('\0'),
            "escapeString: value contains a null byte, which would silently truncate the SQL string");
        if (value.length == 0) return "";
        return _connection.borrow!((auto ref conn) @trusted {
            int error;
            // allocate space for terminating NUL: 2*len + 1
            char[] buf = new char[value.length * 2 + 1];
            auto size = PQescapeStringConn(
                conn._pg_conn,
                &buf[0],        // to
                value.ptr,      // from (value.length > 0 guaranteed above)
                value.length,
                &error);
            enforce!QueryEscapingError(
                error == 0,
                "Cannot escape string %s: %s".format(
                    value, errorMessage));
            // size bytes were written (not counting terminating NUL)
            return buf[0 .. size].idup;
        });
    }

    /** Escape a string for use as an SQL identifier (channel, table or
      * column name).
      *
      * Returns:
      *     The identifier wrapped in double quotes, with internal double
      *     quotes doubled — safe to splice into SQL where an identifier is
      *     expected (e.g. LISTEN, which cannot take $1 parameters).
      **/
    string escapeIdentifier(in string value) {
        enforce!QueryEscapingError(
            !value.canFind('\0'),
            "escapeIdentifier: value contains a null byte, which would silently truncate the identifier");
        return _connection.borrow!((auto ref conn) @trusted {
            char* res = PQescapeIdentifier(
                conn._pg_conn,
                value.length ? value.ptr : "".ptr,
                value.length);
            enforce!QueryEscapingError(
                res !is null,
                "Cannot escape identifier %s: %s".format(value, errorMessage));
            scope(exit) PQfreemem(res);
            return res.fromStringz.idup;
        });
    }

    // --- LISTEN / NOTIFY ---

    /** Subscribe this connection to a notification channel (plain LISTEN;
      * the channel name is identifier-quoted).
      *
      * Notifications are delivered by the server only between transactions —
      * keep the listening connection autocommit and out of any pool, owned by
      * a single consumer.  Subscriptions do NOT survive reconnect: after
      * constructing a fresh Connection, re-issue listen() for every channel.
      **/
    void listen(in string channel) {
        exec("LISTEN " ~ escapeIdentifier(channel));
    }

    /// Unsubscribe this connection from a notification channel.
    void unlisten(in string channel) {
        exec("UNLISTEN " ~ escapeIdentifier(channel));
    }

    /** Return all notifications buffered for this connection — non-blocking.
      *
      * Consumes pending socket input once, then drains libpq's notification
      * queue.  Returns an empty array when nothing is pending; never waits.
      **/
    Notification[] getNotifications() {
        return _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQconsumeInput(conn._pg_conn) == 1,
                "PQconsumeInput failed while checking notifications: " ~ errorMessage);
            return _drainNotifications(conn._pg_conn);
        });
    }

    /** Wait up to `timeout` for notifications on LISTENed channels.
      *
      * Drain-first: notifications libpq buffered during earlier traffic are
      * returned immediately without waiting on the socket — libpq may hold
      * queued notifications while the socket shows nothing new, so waiting
      * first would stall on already-delivered messages.
      *
      * A zero (or negative) timeout is a drain-only, non-blocking check.
      *
      * Returns:
      *     Buffered or newly-arrived notifications; an empty array on
      *     timeout.  An empty result after a readable wake-up is also normal
      *     (spurious readable — e.g. keepalive traffic).
      * Throws:
      *     PequeException when this Connection's WaitStrategy lacks the timed
      *     `bool wait(int fd, WaitMask mask, Duration timeout)` overload.
      **/
    Notification[] waitNotifications(Duration timeout) {
        enforce!NotSupportedError(
            _asyncHooks.waitTimed !is null,
            "waitNotifications requires a WaitStrategy providing "
            ~ "`bool wait(int fd, WaitMask mask, Duration timeout)`; the strategy "
            ~ "used to construct this Connection does not provide it "
            ~ "(PollWaitStrategy and VibeWaitStrategy both do).");

        // (a) Drain first — libpq may hold notifications while the socket is idle.
        auto pending = getNotifications();
        if (pending.length > 0)
            return pending;

        // (b) Bounded wait for new socket data.
        if (!_asyncHooks.waitTimed(_socket(), WaitMask.read, timeout))
            return null;                     // timed out

        // (c) Consume and drain whatever arrived (may legitimately be empty).
        return getNotifications();
    }

    /// Drain libpq's already-buffered notification queue (no socket I/O).
    private static Notification[] _drainNotifications(PGconn* pg) @trusted {
        Notification[] result;
        PGnotify* n;
        while ((n = PQnotifies(pg)) !is null) {
            scope(exit) PQfreemem(n);
            result ~= Notification(
                n.relname.fromStringz.idup,
                n.extra.fromStringz.idup,
                n.be_pid);
        }
        return result;
    }

    // --- Private async loop helpers ---

    /** Get the underlying socket fd for poll() calls. **/
    private int _socket() @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            return PQsocket(conn._pg_conn);
        });
    }

    /** Close the connection immediately, releasing the underlying PGconn.
      *
      * Idempotent and safe on a default-constructed (never-connected) or
      * already-finalized handle: if the refcounted payload was never
      * initialized — or was already destroyed — there is nothing to release
      * and close() is a no-op.
      *
      * If multiple handles share the same SafeRefCounted payload (e.g. a
      * Transaction borrows the connection), the PGconn is finalized as soon
      * as this handle closes it, regardless of other holders' refcounts.
      * Only call close() when you are the sole owner (pool slots always are).
      **/
    void close() @trusted {
        if (!_connection.refCountedStore.isInitialized)
            return;
        _connection.borrow!((auto ref conn) @trusted { conn.close(); });
    }

    /** Expose raw socket fd — package-only, used by pool tests to simulate
      * a dead TCP connection. **/
    package(peque) int socketFd() @trusted { return _socket(); }

    /** Flush the send buffer after PQsendQuery* / PQsendPrepare*.
      *
      * PQflush returns:
      *   0  — all data sent
      *   1  — would block
      *  -1  — error
      *
      * On 1, libpq's protocol requires waiting until the socket is readable
      * OR writable and consuming input before retrying — waiting only for
      * writability can deadlock when both TCP directions are full (the server
      * blocked writing to us stops reading until we consume). PQconsumeInput
      * never blocks (libpq sockets are internally non-blocking), so calling
      * it after a possibly-writable wake-up is safe, and each readable
      * wake-up clears its own condition — no busy-spin.
      **/
    private void _flushLoop() @trusted {
        int fd = _socket();
        _connection.borrow!((auto ref conn) @trusted {
            while (true) {
                int r = PQflush(conn._pg_conn);
                if (r == 0) return;
                enforce!ConnectionError(r > 0, "PQflush failed: " ~ errorMessage);
                _asyncHooks.wait(fd, WaitMask.readWrite);
                enforce!ConnectionError(
                    PQconsumeInput(conn._pg_conn) == 1,
                    "PQconsumeInput failed during flush: " ~ errorMessage);
            }
        });
    }

    /** Ensure the next PQgetResult call will not block: consume socket input
      * until PQisBusy == 0.
      *
      * Unlike _waitForResult, checks PQisBusy BEFORE waiting — between the
      * results of a multi-statement query the next result may already be
      * fully buffered, and the socket would never turn readable again.
      * Without this, PQgetResult for statements after the first blocks inside
      * libpq's own socket read — stalling every fiber of a vibe.d thread.
      **/
    private void _waitWhileBusy(PGconn* pg) @trusted {
        while (PQisBusy(pg) == 1) {
            _asyncHooks.wait(PQsocket(pg), WaitMask.read);
            enforce!ConnectionError(
                PQconsumeInput(pg) == 1,
                "PQconsumeInput failed: " ~ errorMessage);
        }
    }

    /** Reject an unexpected COPY sub-protocol result.
      *
      * No-op unless `cur` has PGRES_COPY_* status. libpq keeps returning
      * fresh COPY results from PQgetResult until the COPY is actually
      * performed, so the collect loops would spin forever. peque does not
      * implement COPY: abort it (end our sending side, drain incoming data),
      * drain all trailing results so the connection stays usable, and throw
      * QueryError. Clears and nulls `cur` when it throws, so callers' cleanup
      * guards can safely `PQclear(cur)` on other error paths.
      **/
    private void _rejectCopy(PGconn* pg, ref PGresult* cur) @trusted {
        immutable st = PQresultStatus(cur);
        if (st != PGRES_COPY_OUT && st != PGRES_COPY_IN && st != PGRES_COPY_BOTH)
            return;
        PQclear(cur);
        cur = null;
        _abortCopy(pg, st);

        // Drain trailing results (the COPY's final status and any further
        // statements of a multi-statement string). A later statement may be
        // another COPY — abort those too instead of spinning on them.
        while (true) {
            _waitWhileBusy(pg);
            auto r = PQgetResult(pg);
            if (r is null) break;
            immutable st2 = PQresultStatus(r);
            PQclear(r);
            if (st2 == PGRES_COPY_OUT || st2 == PGRES_COPY_IN
                    || st2 == PGRES_COPY_BOTH)
                _abortCopy(pg, st2);
        }

        throw new NotSupportedError(
            "COPY TO/FROM STDOUT/STDIN is not supported by peque. "
            ~ "Use COPY with a server-side file, or psql's \\copy.");
    }

    /** Terminate one COPY sub-protocol: end our sending side, drain incoming
      * data. Best-effort: a PQconsumeInput failure mid-abort breaks out
      * silently and the caller still throws the friendly "COPY not supported"
      * QueryError — the underlying connection error surfaces on the next
      * query instead of here.
      **/
    private void _abortCopy(PGconn* pg, ExecStatusType st) @trusted {
        immutable fd = PQsocket(pg);

        // COPY IN / BOTH: end the client→server stream (server responds with
        // an error result carrying this message). 0 = queue full — retry
        // after a readWrite wait + consume (see _flushLoop for the rationale).
        if (st == PGRES_COPY_IN || st == PGRES_COPY_BOTH) {
            while (PQputCopyEnd(pg, "COPY rejected: not supported by peque") == 0) {
                _asyncHooks.wait(fd, WaitMask.readWrite);
                if (PQconsumeInput(pg) != 1) break;
            }
            while (PQflush(pg) == 1) {
                _asyncHooks.wait(fd, WaitMask.readWrite);
                if (PQconsumeInput(pg) != 1) break;
            }
        }

        // COPY OUT / BOTH: drain the server→client stream until it ends.
        if (st == PGRES_COPY_OUT || st == PGRES_COPY_BOTH) {
            char* buf;
            int r;
            while ((r = PQgetCopyData(pg, &buf, 1)) != -1) {
                if (r > 0) { PQfreemem(buf); continue; }
                if (r == -2) break;             // connection trouble — stop
                // r == 0: nothing buffered yet
                _asyncHooks.wait(fd, WaitMask.read);
                if (PQconsumeInput(pg) != 1) break;
            }
        }
    }

    /** Wait until the server result is ready (PQisBusy == 0).
      *
      * Loop: wait for readable → PQconsumeInput → check PQisBusy.
      **/
    private void _waitForResult() @trusted {
        int fd = _socket();
        _connection.borrow!((auto ref conn) @trusted {
            while (true) {
                _asyncHooks.wait(fd, WaitMask.read);
                enforce!ConnectionError(
                    PQconsumeInput(conn._pg_conn) == 1,
                    "PQconsumeInput failed: " ~ errorMessage);
                if (PQisBusy(conn._pg_conn) == 0) return;
            }
        });
    }

    /** Collect the last result and discard any intermediate ones.
      *
      * PQsendQuery can produce multiple results for multi-statement strings.
      * We return the last one (matching PQexec behaviour) and PQclear all
      * earlier ones. Caller must call ensureQueryOk() on the returned Result.
      * Use _collectAllResults() when all results are needed.
      **/
    private Result _collectResult() @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            auto cur = PQgetResult(conn._pg_conn);
            enforce!ConnectionError(cur !is null,
                "PQgetResult returned null — query send failed");
            // Free the in-flight result if the walk throws mid-way
            // (_rejectCopy nulls cur before throwing, so no double-free).
            scope(failure) if (cur !is null) PQclear(cur);
            // Walk to the last result; PQclear each intermediate one.
            while (true) {
                _rejectCopy(conn._pg_conn, cur);    // throws on COPY
                _waitWhileBusy(conn._pg_conn);      // never block in PQgetResult
                auto next = PQgetResult(conn._pg_conn);
                if (next is null) break;
                PQclear(cur);
                cur = next;
            }
            auto result = Result(cur);
            cur = null;                             // ownership transferred
            return result;
        });
    }

    /** Collect every result produced by a multi-statement query.
      *
      * Returns one Result per statement in order. Caller must call
      * ensureQueryOk() on each result (execMulti() does this automatically).
      *
      * Implementation note: raw PGresult* pointers are collected first, then
      * wrapped into Result via moveEmplace. This avoids growing a Result[]
      * inside a non-pure @trusted context, which would instantiate
      * core.internal.lifetime.__doPostblit!Result with non-pure attributes and
      * cause a linker symbol mismatch when the library is linked against code
      * compiled with -allinst (e.g. the migrate subpackage tests).
      **/
    private Result[] _collectAllResults() @trusted {
        auto ptrs = _connection.borrow!((auto ref conn) @trusted {
            PGresult*[] acc;
            scope(failure) foreach (p; acc) PQclear(p);
            while (true) {
                _waitWhileBusy(conn._pg_conn);      // never block in PQgetResult
                auto cur = PQgetResult(conn._pg_conn);
                if (cur is null) break;
                _rejectCopy(conn._pg_conn, cur);    // throws on COPY (owns cur)
                acc ~= cur;
            }
            return acc;
        });
        Result[] results;
        results.length = ptrs.length;
        foreach (i, p; ptrs) {
            import core.lifetime: moveEmplace;
            auto r = Result(p);
            moveEmplace(r, results[i]);
        }
        return results;
    }

    // --- Public query API ---

    /** Execute query as raw SQL (async path via PQsendQuery).
      *
      * Supports multi-statement strings (separated by semicolons).
      * The LAST result is returned (matching PQexec behaviour). Use execMulti()
      * when you need all results from a multi-statement string.
      *
      * This method is NOT safe for user-supplied input — use execParams instead.
      *
      * Params:
      *     query = SQL query string (hardcoded/trusted SQL only)
      * Returns: Result of the last statement
      **/
    auto exec(in string query) {
        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsendQuery(conn._pg_conn, query.toStringz) == 1,
                "PQsendQuery failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        auto r = _collectResult();
        return r.ensureQueryOk();
    }

    /** Execute a multi-statement SQL string and return every result.
      *
      * Like exec(), but collects all results instead of only the last one.
      * Each result is validated with ensureQueryOk() — any statement that
      * fails causes a QueryError to be thrown immediately.
      *
      * This method is NOT safe for user-supplied input — use execParams instead.
      *
      * Params:
      *     query = SQL query string with one or more semicolon-separated statements
      * Returns: Array of Result, one per statement, in execution order
      **/
    auto execMulti(in string query) {
        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsendQuery(conn._pg_conn, query.toStringz) == 1,
                "PQsendQuery failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        auto results = _collectAllResults();
        foreach (ref r; results) r.ensureQueryOk();
        return results;
    }

    /** Execute query with parameters (async path via PQsendQueryParams).
      *
      * Safe for user-supplied values — parameters are passed separately,
      * never interpolated into the SQL string.
      *
      * Params:
      *     query  = SQL query string with $1, $2, … placeholders
      *     params = variadic D values, converted to PostgreSQL text format
      * Returns: Result
      **/
    auto execParams(in string query) {
        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsendQueryParams(
                    conn._pg_conn,
                    query.toStringz,
                    0, null, null, null, null,
                    PGFormat.TEXT) == 1,
                "PQsendQueryParams failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        auto r = _collectResult();
        return r.ensureQueryOk();
    }

    /// ditto
    auto execParams(T...)(in string query, T params) {
        import std.conv: to;

        PGValue[T.length] values = mixin(() {
            string r = "[";
            static foreach (i; 0 .. T.length) {
                if (i > 0) r ~= ", ";
                r ~= "convertToPG!(T[" ~ i.to!string ~ "])(params[" ~ i.to!string ~ "])";
            }
            return r ~ "]";
        }());
        return execParams(query, values[]);
    }

    /** Execute a parameterised query from a pre-built PGValue slice.
      *
      * Package-visible overload used by the ORM QuerySet (peque.orm.*), which
      * accumulates PGValue params at runtime across multiple .where() calls and
      * cannot use the compile-time-variadic execParams(T...) overload.
      *
      * Params:
      *     query  = SQL with $1, $2, … placeholders
      *     params = already-converted PGValue parameters (empty slice → no params)
      * Returns: Result
      **/
    Result execParams(string query, in PGValue[] params) {
        if (params.length == 0) return execParams(query);

        // The Bind message carries an int16 parameter count. Over the limit
        // libpq fails client-side without touching the socket, so this is a
        // caller error, not a broken link — the distinction matters to anyone
        // retrying on ConnectionError.
        enforce!QueryClientError(
            params.length <= 65535,
            format!("Query binds %s parameters, over PostgreSQL's limit of " ~
                    "65535 per statement. Split the values into batches.")(
                    params.length));

        auto pTypes   = new uint[params.length];
        auto pValues  = new const(char)*[params.length];
        auto pLengths = new int[params.length];
        auto pFormats = new int[params.length];

        foreach (i, ref v; params) {
            pTypes[i]   = v.type;
            pFormats[i] = v.format;
            if (v.isNull) {
                pValues[i]  = null;
                pLengths[i] = 0;
            } else {
                pValues[i]  = &v.value[0];
                pLengths[i] = v.length;
            }
        }

        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsendQueryParams(
                    conn._pg_conn,
                    query.toStringz,
                    cast(int)params.length,
                    pTypes.ptr,
                    pValues.ptr,
                    pLengths.ptr,
                    pFormats.ptr,
                    PGFormat.TEXT) == 1,
                "PQsendQueryParams failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        return _collectResult().ensureQueryOk();
    }

    /** Prepare a named server-side statement.
      *
      * Returns a move-only PreparedStatement handle. The statement is
      * deallocated automatically when the handle goes out of scope.
      *
      * The name must match ^[A-Za-z_][A-Za-z0-9_]*$ — validated before sending
      * to prevent injection through the statement name.
      *
      * PreparedStatement must not outlive this Connection (or pool borrow scope).
      *
      * Params:
      *     name  = server-side statement name (alphanumeric + underscore)
      *     query = SQL query with $1, $2, … placeholders
      * Returns: PreparedStatement handle
      **/
    auto prepare(in string name, in string query) {
        import std.ascii: isAlpha, isAlphaNum;
        import std.algorithm: all;
        enforce!QueryClientError(
            name.length > 0 &&
            (name[0] == '_' || isAlpha(name[0])) &&
            name[1 .. $].all!(c => c == '_' || isAlphaNum(c)),
            "PreparedStatement name must be alphanumeric+underscore, got: " ~ name);

        _connection.borrow!((auto ref conn) @trusted {
            enforce!ConnectionError(
                PQsendPrepare(
                    conn._pg_conn,
                    name.toStringz,
                    query.toStringz,
                    0, null) == 1,
                "PQsendPrepare failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        _collectResult().ensureQueryOk();
        return PreparedStatement(name, this);
    }

    auto begin() { return exec("BEGIN"); }

    auto commit() { return exec("COMMIT"); }

    auto rollback() { return exec("ROLLBACK"); }

    /** Execute fun inside a transaction.
      *
      * Issues BEGIN (with the requested isolation level) before calling fun.
      * On success, commits or rolls back depending on onSuccess. On failure
      * (exception), always rolls back.
      *
      * Params:
      *     onSuccess = whether to commit or rollback when fun completes without
      *                 throwing. Defaults to OnSuccess.commit. Use
      *                 OnSuccess.rollback for dry-runs and tests that must not
      *                 persist changes.
      *     isolation = transaction isolation level. Defaults to
      *                 IsolationLevel.readCommitted — always sets the level
      *                 explicitly regardless of server configuration. Use
      *                 IsolationLevel.serverDefault to defer to the server,
      *                 role, or database configured default instead.
      *     fun       = delegate receiving a ref Transaction handle; use it to
      *                 run queries inside the transaction.
      *
      * Returns: whatever fun returns (void is allowed)
      **/
    /** Refuse to open a transaction inside one that is already open.
      *
      * PostgreSQL ignores a nested BEGIN, so the inner COMMIT would commit the
      * OUTER transaction and the outer rollback would find nothing to undo —
      * silent data loss. savepoint() is the supported way to nest.
      **/
    private void _rejectNestedTransaction() {
        immutable st = transactionStatus();
        if (st == PQTRANS_IDLE) return;

        if (st == PQTRANS_INTRANS)
            throw new QueryClientError(
                "transaction() called while a transaction is already open. A " ~
                "nested BEGIN is ignored by PostgreSQL, so the inner COMMIT " ~
                "would commit the outer transaction. Use the Transaction " ~
                "handle's savepoint() to nest.");

        if (st == PQTRANS_INERROR)
            throw new QueryClientError(
                "transaction() called inside a transaction that has already " ~
                "failed. PostgreSQL accepts nothing but ROLLBACK until it " ~
                "ends, so nothing here could be committed.");

        if (st == PQTRANS_ACTIVE)
            throw new QueryClientError(
                "transaction() called while a command is still in flight. " ~
                "peque waits for every result before returning, so the " ~
                "Connection is being used from two places at once — borrow " ~
                "one per task from a ConnectionPool.");

        throw new ConnectionError(
            "Cannot determine transaction status: " ~ errorMessage);
    }

    auto transaction(
            OnSuccess onSuccess = OnSuccess.commit,
            IsolationLevel isolation = IsolationLevel.readCommitted,
            T)(scope T delegate(ref Transaction) fun) {
        _rejectNestedTransaction();
        auto tx = Transaction(this);
        static if (isolation == IsolationLevel.serverDefault)
            exec("BEGIN");
        else static if (isolation == IsolationLevel.readCommitted)
            exec("BEGIN ISOLATION LEVEL READ COMMITTED");
        else static if (isolation == IsolationLevel.repeatableRead)
            exec("BEGIN ISOLATION LEVEL REPEATABLE READ");
        else static if (isolation == IsolationLevel.serializable)
            exec("BEGIN ISOLATION LEVEL SERIALIZABLE");
        scope(failure) tx.rollback();
        static if (onSuccess == OnSuccess.commit)
            scope(success) tx.commit();
        else
            scope(success) tx.rollback();
        return fun(tx);
    }
}


/** Restricted connection handle passed into the delegate by Connection.transaction().
  *
  * Exposes exec, execParams, and escapeString but intentionally hides commit() and
  * rollback() — transaction lifetime is managed entirely by Connection.transaction().
  * This prevents accidental early commit/rollback inside the delegate.
  *
  * Transaction is not copyable and must not be stored beyond the delegate scope.
  **/
struct Transaction {
    private Connection _conn;
    private uint _spCounter;

    @disable this(this);
    @disable void opAssign(typeof(this));

    package(peque) this(Connection conn) { _conn = conn; }

    /// Execute raw SQL (forwards to Connection.exec).
    auto exec(in string query) { return _conn.exec(query); }

    /// Execute query with parameters (forwards to Connection.execParams).
    auto execParams(in string query) { return _conn.execParams(query); }

    /// ditto
    auto execParams(T...)(in string query, T params) {
        return _conn.execParams(query, params);
    }

    /// ditto — forwards pre-built PGValue slice to Connection.execParams(PGValue[]).
    auto execParams(string query, in PGValue[] params) {
        return _conn.execParams(query, params);
    }

    /// Escape a string value (forwards to Connection.escapeString).
    string escapeString(in string value) { return _conn.escapeString(value); }

    /** Execute fun inside a savepoint.
      *
      * Creates a named savepoint before calling fun. On success, releases the
      * savepoint (or rolls back to it and releases on OnSuccess.rollback). On
      * failure (exception), rolls back to the savepoint and releases it, leaving
      * the enclosing transaction intact.
      *
      * Savepoint names are auto-generated from a per-transaction counter
      * (sp_0, sp_1, …) — unique within the transaction, no user input required.
      *
      * fun receives ref to the same Transaction, so business logic is unaware
      * of savepoint nesting depth. Savepoints may be nested arbitrarily.
      *
      * Params:
      *     onSuccess = OnSuccess.commit (default) releases the savepoint;
      *                 OnSuccess.rollback rolls back to it and releases it —
      *                 useful for dry-run sub-operations inside a transaction.
      *     fun       = delegate to execute inside the savepoint.
      *
      * Returns: whatever fun returns (void is allowed)
      **/
    auto savepoint(OnSuccess onSuccess = OnSuccess.commit, T)(
            scope T delegate(ref Transaction) fun) {
        auto name = "sp_%d".format(_spCounter++);
        _conn.exec("SAVEPOINT " ~ name);
        scope(failure) {
            _conn.exec("ROLLBACK TO SAVEPOINT " ~ name);
            _conn.exec("RELEASE SAVEPOINT " ~ name);
        }
        static if (onSuccess == OnSuccess.commit)
            scope(success) _conn.exec("RELEASE SAVEPOINT " ~ name);
        else
            scope(success) {
                _conn.exec("ROLLBACK TO SAVEPOINT " ~ name);
                _conn.exec("RELEASE SAVEPOINT " ~ name);
            }
        return fun(this);
    }

    // Package-only — called exclusively by Connection.transaction() scope guards.
    package(peque) auto commit()   { return _conn.commit(); }
    package(peque) auto rollback() { return _conn.rollback(); }
}


/** RAII handle to a server-side prepared statement.
  *
  * Move-only — copy is disabled. Destructor issues DEALLOCATE.
  * Must not outlive the Connection (or pool borrow scope) that created it.
  *
  * Obtain via Connection.prepare():
  * ---
  * auto stmt = conn.prepare("find_user",
  *     "SELECT id, name FROM users WHERE id = $1");
  * auto result = stmt.exec(42);
  * // stmt goes out of scope → DEALLOCATE find_user sent automatically
  * ---
  **/
struct PreparedStatement {
    private string      _name;
    private Connection  _conn;   // copy of Connection (bumps SafeRefCounted refcount)
    private bool        _valid = false;

    @disable this(this);
    @disable void opAssign(typeof(this));

    package(peque) this(string name, Connection conn) {
        _name  = name;
        _conn  = conn;
        _valid = true;
    }

    ~this() @trusted {
        if (!_valid) return;
        // Best-effort DEALLOCATE — ignore errors (connection may be closing)
        try { _conn.exec("DEALLOCATE " ~ _name); } catch (Exception) {}
        _valid = false;
    }

    /** Execute the prepared statement with the given parameters.
      *
      * Uses the same async path as execParams (PQsendQueryPrepared + flush/consume loop).
      **/
    auto exec(T...)(T params) {
        static if (T.length == 0) {
            _conn._connection.borrow!((auto ref conn) @trusted {
                enforce!ConnectionError(
                    PQsendQueryPrepared(
                        conn._pg_conn,
                        _name.toStringz,
                        0, null, null, null,
                        PGFormat.TEXT) == 1,
                    "PQsendQueryPrepared failed: " ~ _conn.errorMessage);
            });
        } else {
            uint[T.length] param_types;
            const(char)*[T.length] param_values;
            int[T.length] param_lengths;
            int[T.length] param_formats;

            PGValue[T.length] values = mixin(() {
                import std.conv: to;
                string r = "[";
                static foreach (i; 0 .. T.length) {
                    if (i > 0) r ~= ", ";
                    r ~= "convertToPG!(T[" ~ i.to!string ~ "])(params[" ~ i.to!string ~ "])";
                }
                return r ~ "]";
            }());
            static foreach (i; 0 .. T.length) {
                param_types[i]   = values[i].type;
                param_formats[i] = values[i].format;
                if (values[i].isNull) {
                    param_values[i]  = null;
                    param_lengths[i] = 0;
                } else {
                    param_values[i]  = &values[i].value[0];
                    param_lengths[i] = values[i].length;
                }
            }

            _conn._connection.borrow!((auto ref conn) @trusted {
                enforce!ConnectionError(
                    PQsendQueryPrepared(
                        conn._pg_conn,
                        _name.toStringz,
                        T.length,
                        param_values.ptr,
                        param_lengths.ptr,
                        param_formats.ptr,
                        PGFormat.TEXT) == 1,
                    "PQsendQueryPrepared failed: " ~ _conn.errorMessage);
            });
        }

        _conn._flushLoop();
        _conn._waitForResult();
        auto r = _conn._collectResult();
        return r.ensureQueryOk();
    }

    /// Returns the server-side statement name.
    string name() const { return _name; }
}


unittest {
    import std.exception;

    Connection("some bad connection string").assertThrown!ConnectionError;
}

// PQserverVersion decoding: two-part since PG 10 (10.x included), three-part before
unittest {
    assert(Connection._parseServerVersion(160001) == Version(16, 1));
    assert(Connection._parseServerVersion(140000) == Version(14, 0));
    assert(Connection._parseServerVersion(100005) == Version(10, 5));
    assert(Connection._parseServerVersion(100023) == Version(10, 23));
    assert(Connection._parseServerVersion(90605)  == Version(9, 6, 5));
}
