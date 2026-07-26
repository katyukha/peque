module peque.connection;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;
private import std.array: array;
private import std.algorithm: map;

private import versioned: Version;

private import peque.lib;
private import peque.exception;
private import peque.pg_type;
private import peque.pg_format;
private import peque.result;
private import peque.wait_strategy;
private import peque.converter: PGValue;


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
  **/
private struct RuntimeWaitStrategy {
    void delegate(int fd) @safe waitReadable;
    void delegate(int fd) @safe waitWritable;
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
      * Pass a custom WaitStrategy as the second argument to override:
      * ---
      * // vibe.d pool factory:
      * auto conn = Connection(connStr, VibeWaitStrategy());
      *
      * // Tests:
      * MockWaitStrategy mock;
      * auto conn = Connection(connStr, MockWS(&mock));
      * ---
      **/
    this(WS = PollWaitStrategy)(in string conn_info, WS ws = WS.init)
            if (isWaitStrategy!WS) {
        _connection = ConnectionInternal(conn_info);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
        _setHooks(ws);
    }

    /// ditto
    this(WS = PollWaitStrategy)(in string[string] params, WS ws = WS.init)
            if (isWaitStrategy!WS) {
        _connection = ConnectionInternal(params);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
        _setHooks(ws);
    }

    /// ditto
    this(WS = PollWaitStrategy)(in string dbname, in string user, in string password,
            in string host, in string port, WS ws = WS.init)
            if (isWaitStrategy!WS) {
        string[string] p;
        if (dbname && dbname.length > 0)   p["dbname"]   = dbname.dup;
        if (user && user.length > 0)       p["user"]     = user.dup;
        if (password && password.length > 0) p["password"] = password.dup;
        if (host && host.length > 0)       p["host"]     = host.dup;
        if (port && port.length > 0)       p["port"]     = port.dup;
        this(p, ws);
    }

    private void _setHooks(WS)(WS ws) if (isWaitStrategy!WS) {
        _asyncHooks = RuntimeWaitStrategy(
            (int fd) @trusted { ws.waitReadable(fd); },
            (int fd) @trusted { ws.waitWritable(fd); });
    }

    auto serverVersion() {
        // See docs here: https://www.postgresql.org/docs/current/libpq-status.html#LIBPQ-PQSERVERVERSION
        int v = _connection.borrow!((auto ref conn) @trusted => PQserverVersion(conn._pg_conn));
        uint major_version = v / 10000;
        uint minor_version = (v - major_version * 10000) / 100;
        uint patch_version = v - major_version * 10000 - minor_version * 100;
        if (major_version > 10 && minor_version == 0)
            return Version(major_version, patch_version);
        return Version(major_version, minor_version, patch_version);
    }

    /// Check status of connection
    auto status() { return _connection.borrow!((auto ref conn) @trusted => PQstatus(conn._pg_conn)); }

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
        import std.algorithm: canFind;
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

    // --- Private async loop helpers ---

    /** Get the underlying socket fd for poll() calls. **/
    private int _socket() @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            return PQsocket(conn._pg_conn);
        });
    }

    /** Close the connection immediately, releasing the underlying PGconn.
      *
      * Idempotent — safe to call on an already-closed connection.
      * If multiple handles share the same SafeRefCounted payload (e.g. a
      * Transaction borrows the connection), the PGconn is finalized as soon
      * as this handle closes it, regardless of other holders' refcounts.
      * Only call close() when you are the sole owner (pool slots always are).
      **/
    void close() @trusted {
        _connection.borrow!((auto ref conn) @trusted { conn.close(); });
    }

    /** Expose raw socket fd — package-only, used by pool tests to simulate
      * a dead TCP connection. **/
    package(peque) int socketFd() @trusted { return _socket(); }

    /** Flush the send buffer after PQsendQuery* / PQsendPrepare*.
      *
      * PQflush returns:
      *   0  — all data sent
      *   1  — would block; wait for fd to be writable then retry
      *  -1  — error
      **/
    private void _flushLoop() @trusted {
        int fd = _socket();
        _connection.borrow!((auto ref conn) @trusted {
            while (true) {
                int r = PQflush(conn._pg_conn);
                if (r == 0) return;
                enforce!QueryError(r > 0, "PQflush failed: " ~ errorMessage);
                _asyncHooks.waitWritable(fd);
            }
        });
    }

    /** Wait until the server result is ready (PQisBusy == 0).
      *
      * Loop: waitReadable → PQconsumeInput → check PQisBusy.
      **/
    private void _waitForResult() @trusted {
        int fd = _socket();
        _connection.borrow!((auto ref conn) @trusted {
            while (true) {
                _asyncHooks.waitReadable(fd);
                enforce!QueryError(
                    PQconsumeInput(conn._pg_conn) == 1,
                    "PQconsumeInput failed: " ~ errorMessage);
                if (PQisBusy(conn._pg_conn) == 0) return;
            }
        });
    }

    /** Collect the last result and clear any intermediate ones.
      *
      * PQsendQuery can produce multiple results (multi-statement strings).
      * We return the last one (matching PQexec behaviour) and PQclear all
      * earlier ones. Caller must call ensureQueryOk() on the returned Result.
      **/
    private Result _collectResult() @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            auto cur = PQgetResult(conn._pg_conn);
            enforce!QueryError(cur !is null,
                "PQgetResult returned null — query send failed");
            // Walk to the last result; PQclear each intermediate one.
            PGresult* next;
            while ((next = PQgetResult(conn._pg_conn)) !is null) {
                PQclear(cur);
                cur = next;
            }
            return Result(cur);
        });
    }

    // --- Public query API ---

    /** Execute query as raw SQL (async path via PQsendQuery).
      *
      * Supports multi-statement strings (separated by semicolons).
      * Only the result of the first statement is returned.
      *
      * This method is NOT safe for user-supplied input — use execParams instead.
      *
      * Params:
      *     query = SQL query string (hardcoded/trusted SQL only)
      * Returns: Result of the first statement
      **/
    auto exec(in string query) {
        _connection.borrow!((auto ref conn) @trusted {
            enforce!QueryError(
                PQsendQuery(conn._pg_conn, query.toStringz) == 1,
                "PQsendQuery failed: " ~ errorMessage);
        });
        _flushLoop();
        _waitForResult();
        auto r = _collectResult();
        return r.ensureQueryOk();
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
            enforce!QueryError(
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
        import std.range: iota;
        import std.conv;
        import peque.converter;

        // Build a stack-allocated PGValue array and pass a slice to the overload
        // below.
        PGValue[T.length] values = mixin(() {
            static assert(T.length >= 0, "execParams called with no args!");
            auto r = "[convertToPG!(T[0])(params[0])";
            static if (T.length > 1)
                static foreach(i; iota(1, T.length))
                    r ~= ", convertToPG!(T[" ~ i.to!string ~ "])(params[" ~ i.to!string ~ "]) ";
            r ~= "]";
            return r;
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
    package(peque) Result execParams(string query, in PGValue[] params) {
        if (params.length == 0) return execParams(query);

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
            enforce!QueryError(
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
        import std.regex: matchFirst;
        enforce!QueryError(
            !matchFirst(name, `^[A-Za-z_][A-Za-z0-9_]*$`).empty,
            "PreparedStatement name must be alphanumeric+underscore, got: " ~ name);

        _connection.borrow!((auto ref conn) @trusted {
            enforce!QueryError(
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
    auto transaction(
            OnSuccess onSuccess = OnSuccess.commit,
            IsolationLevel isolation = IsolationLevel.readCommitted,
            T)(scope T delegate(ref Transaction) fun) {
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
    package(peque) auto execParams(string query, in PGValue[] params) {
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
        import std.range: iota;
        import std.conv;
        import peque.converter;

        static if (T.length == 0) {
            _conn._connection.borrow!((auto ref conn) @trusted {
                enforce!QueryError(
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
                auto r = "[convertToPG!(T[0])(params[0])";
                static if (T.length > 1)
                    static foreach(i; iota(1, T.length))
                        r ~= ", convertToPG!(T[" ~ i.to!string ~ "])(params[" ~ i.to!string ~ "]) ";
                r ~= "]";
                return r;
            }());
            static foreach(i; T.length.iota) {
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
                enforce!QueryError(
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
