module peque.connection;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;

private import peque.c;
private import peque.exception: PequeException;

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
        enforce!PequeException(
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
    auto status() @trusted { return PQstatus(_connection._pg_conn); }
    //auto status() { return _connection.borrow!((auto ref conn) @trusted => PQstatus(conn._pg_conn)); }

    /// Return most recent error message
    auto errorMessage() @trusted {
        return PQerrorMessage(_connection._pg_conn).fromStringz.idup;
    }

    auto exec(in string command) @trusted {
        return Result(
            PQexec(_connection._pg_conn, command.toStringz)
        );
    }
}


