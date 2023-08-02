module peque.connection;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;

private import peque.c;
private import peque.exception;
private import peque.pg_type;
private import peque.result;

/// Connection to PostgreSQL database.
@safe struct Connection {

    /// Wrapper for PGconn to be used for ConnectionInternal refcounted struct
    private struct ConnectionInternalData {
        PGconn* _pg_conn;

        this(in string conn_info) @trusted {
            _pg_conn = PQconnectdb(conn_info.toStringz);
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
            status == CONNECTION_OK,
            "Cannot connect to db: %s!".format(errorMessage));
    }

    this(in string dbname, in string user, in string password,
            in string host, in string port) {
        // TODO: Use PQescapeStringConn to escape connection params
        this(
            "dbname='%s' user='%s' password='%s' host='%s' port='%s'".format(
                dbname, user, password, host, port));
    }

    /// Check status of connection
    //auto status() @trusted { return PQstatus(_connection._pg_conn); }
    auto status() { return _connection.borrow!((auto ref conn) @trusted => PQstatus(conn._pg_conn)); }

    /// Return most recent error message
    auto errorMessage() @trusted {
        return PQerrorMessage(_connection._pg_conn).fromStringz.idup;
    }

    /** Escape value as postgresql string
      *
      * Params:
      *     value = string value to escape
      * Returns:
      *     Escaped string value, but without surrounding single quotes.
      **/
    string escapeString(in string value) @trusted {
        return _connection.borrow!((auto ref conn) @trusted {
            int error;
            char[] buf = new char[value.length * 2];
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
            return buf[0 .. size].idup;
        });
    }

    /** Execute query
      *
      * Params:
      *     query = SQL query to execute
      *
      * Returns: PequeResult
      **/
    auto exec(in string query) {
        return Result(
            _connection.borrow!((auto ref conn) @trusted {
                return PQexec(_connection._pg_conn, query.toStringz);
            })
        );
    }

    auto execParams(T...)(in string query, T params) {
        import std.meta;
        import std.range: iota;
        import std.conv;
        import std.string: representation;
        import std.traits:
            isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint;
        import peque.converter;

        uint[T.length] param_types;
        const(char)*[T.length] param_values;
        int[T.length] param_lengths;
        int[T.length] param_formats;

        // Need it here to keep reference for value
        string[T.length] values;

        static foreach(i; T.length.iota) {
            values[i] = params[i].to!(string);
            param_values[i] = cast(const(char)*)values[i].toStringz;
            param_types[i] = PGType.TEXT;
            param_lengths[i] = values[i].length.to!int;
            param_formats[i] = 0;
        }

        //auto pg_result = _connection.borrow!((auto ref conn) @trusted {
        auto pg_result = (auto ref conn) @trusted {
             return PQexecParams(
                     conn._pg_conn,
                     query.toStringz,
                     T.length,  // param length
                     param_types.ptr,
                     param_values.ptr,
                     param_lengths.ptr,
                     param_formats.ptr,
                     0,  // text result format
            );
        }(_connection);
        //});
        return Result(pg_result);
    }
}


@safe unittest {
    import std.exception;

    Connection("some bad connection string").assertThrown!ConnectionError;
}

