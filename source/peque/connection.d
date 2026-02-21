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

        ~this() @trusted {
            if (_pg_conn !is null) {
                PQfinish(_pg_conn);
                _pg_conn = null;
            }
        }

        // Must not be copiable
        @disable this(this);

        // Must not be assignable
        @disable void opAssign(typeof(this));
    }

    /// Ref-counted connection to postgres
    package(peque) alias SafeRefCounted!(
        ConnectionInternalData,
        RefCountedAutoInitialize.no,
    ) ConnectionInternal;


    private ConnectionInternal _connection;

    this(in string conn_info) {
        _connection = ConnectionInternal(conn_info);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
    }

    this(in string[string] params) {
        _connection = ConnectionInternal(params);
        enforce!ConnectionError(
            _connection.borrow!((auto ref conn) @trusted => conn._pg_conn !is null),
            "Cannot connect to db: PQconnectdb() FAILED");
        enforce!ConnectionError(
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
    }

    this(in string dbname, in string user, in string password,
            in string host, in string port) {
        string[string] params;
        if (dbname && dbname.length > 0)
            params["dbname"] = dbname.dup;
        if (user && user.length > 0)
            params["user"] = user.dup;
        if (password && password.length > 0)
            params["password"] = password.dup;
        if (host && host.length > 0)
            params["host"] = host.dup;
        if (port && port.length > 0)
            params["port"] = port.dup;
        this(params);
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

    /** Escape value as postgresql string
      *
      * Params:
      *     value = string value to escape
      * Returns:
      *     Escaped string value, but without surrounding single quotes.
      **/
    string escapeString(in string value) {
        return _connection.borrow!((auto ref conn) @trusted {
            int error;
            // allocate space for terminating NUL: 2*len + 1
            char[] buf = new char[value.length * 2 + 1];
            auto size = PQescapeStringConn(
                conn._pg_conn,
                &buf[0],      // to
                &value[0],   // from
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

    /** Execute query as raw SQL.
      * This is not recommended for queries with parameters,
      * as it may lead to SQL injection. Perefer usage of execParams instead.
      *
      * Params:
      *     query = SQL query to execute
      *
      * Returns: PequeResult
      **/
    auto exec(in string query) {
        auto res = Result(
            _connection.borrow!((auto ref conn) @trusted {
                return PQexec(conn._pg_conn, query.toStringz);
            })
        );
        return res.ensureQueryOk();
    }

    /** Execute query with parameters
      *
      * Params:
      *     query = SQL query to exexecute
      *     params = variadic parameters for query.
      *
      * Returns: PequeResult
      **/
    auto execParams(in string query) {
        auto pg_result = _connection.borrow!((auto ref conn) @trusted {
             return PQexecParams(
                     conn._pg_conn,
                     query.toStringz,
                     0,  // param length
                     null,  // param types
                     null,  // param_values.ptr,
                     null,  // param_lengths.ptr,
                     null,  // param_formats.ptr,
                     PGFormat.TEXT,  // text result format
            );
        });
        auto res = Result(pg_result);
        // TODO: Use template param to decide where we need to ensureOk or not.
        //       Also, make it in same way for `exec`
        return res.ensureQueryOk();
    }

    /// ditto
    auto execParams(T...)(in string query, T params) {
        import std.range: iota;
        import std.conv;
        import peque.converter;

        uint[T.length] param_types;
        const(char)*[T.length] param_values;
        int[T.length] param_lengths;
        int[T.length] param_formats;

        /* We have to convert all params to PGValue and keep references for them
         * while PQexecParams completed.
         *
         * This is done via string mixin to avoid copying elements of
         * array of PGValues.
         */
        PGValue[T.length] values = mixin(() {
            static assert(T.length >= 0, "execParams called with no args!");
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

        auto pg_result = _connection.borrow!((auto ref conn) @trusted {
        //auto pg_result = (auto ref conn) @trusted {
             return PQexecParams(
                     conn._pg_conn,
                     query.toStringz,
                     T.length,  // param length
                     param_types.ptr,
                     param_values.ptr,
                     param_lengths.ptr,
                     param_formats.ptr,
                     PGFormat.TEXT,  // text result format
            );
        //}(_connection);
        });
        auto res = Result(pg_result);
        return res.ensureQueryOk();
    }


    auto begin() { return execParams("BEGIN"); }

    auto commit() { return execParams("COMMIT"); }

    auto rollback() { return execParams("ROLLBACK"); }

    /** Execute fun inside a transaction.
      *
      * Calls BEGIN before fun, COMMIT on success, and ROLLBACK if fun throws.
      *
      * Params:
      *     fun = delegate to execute inside the transaction
      *
      * Returns: whatever fun returns (void is allowed)
      **/
    auto transaction(T)(scope T delegate() fun) {
        begin();
        scope(failure) rollback();
        scope(success) commit();
        return fun();
    }
}


unittest {
    import std.exception;

    Connection("some bad connection string").assertThrown!ConnectionError;
}

