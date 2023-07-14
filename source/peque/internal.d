module peque.internal;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;

private import peque.c;
private import peque.exception: PequeException;


@safe struct Result {
    /// Refcounted wrapper for PGresult to be used as ResultInternal.
    private struct ResultInternalData {
        PGresult* _pg_result;

        this(PGresult* pg_result) { _pg_result = pg_result; }

        ~this() @trusted {
            if (_pg_result !is null) {
                PQclear(_pg_result);
                _pg_result = null;
            }
        }

        // Must not be copiable
        @disable this(this);

        // Must not be assignable
        @disable void opAssign(typeof(this));
    }

    /// Ref-counted connection to postgres
    package(peque) alias SafeRefCounted!(
        ResultInternalData,
        RefCountedAutoInitialize.no,
    ) ResultInternal;

    private ResultInternal _result;

    package(peque) this(PGresult* result) {
        _result = ResultInternal(result);
    }

    package(peque) void opAssign(Result res) {
        _result = res._result;
    }

    /// Return status of result as libpq enumeration
    auto status() @trusted {
        const struct ResultStatus {
            ExecStatusType statusType;

            this(in ExecStatusType statusType) {
                this.statusType = statusType;
            }

            /// Return string representation of result status
            string toString() const {
                return PQresStatus(statusType).fromStringz.idup;
            }
        }

        return ResultStatus(PQresultStatus(_result._pg_result));
    
    }

    /// Return error message related to this result
    string errorMessage() @trusted {
        return PQresultErrorMessage(_result._pg_result).fromStringz.idup;
    }

    /// Ensure that result is Ok
    auto ensureQueryOk() {
        static immutable bad_states = [
            PGRES_FATAL_ERROR,
            PGRES_BAD_RESPONSE,
            PGRES_EMPTY_QUERY,
        ];
        if (bad_states.canFind(status.statusType))
            throw new PequeException(errorMessage);

        return this;
    }

    /// Return number of rows fetched.
    auto nrows() @trusted { return PQntuples(_result._pg_result); }

    /// Return number of columns fetched.
    auto ncols() @trusted { return PQnfields(_result._pg_result); }

}


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
        this(
            "dbname='%s' user='%s' password='%s' host='%s' port='%s'".format(
                dbname, user, password, host, port));
    }

    /// Check status of connection
    auto status() @trusted { return PQstatus(_connection._pg_conn); }

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


@safe unittest {
    import std.stdio;

    auto c = Connection("peque-test", "peque", "peque", "localhost", "5432");

    auto res = c.exec("
        DROP TABLE IF EXISTS peque_test;
        CREATE TABLE peque_test (
            id      serial,
            code    char(5),
            title   varchar(40)
        );
        INSERT INTO peque_test (code, title)
        VALUES ('t1', 'Test 1'),
               ('t2', 'Test 2'),
               ('t3', 'Test 3'),
               ('r4', 'Test 4');
    ");
    res.ensureQueryOk;
    assert(res.nrows == 0);
    assert(res.ncols == 0);

    res = c.exec("SELECT code, title FROM peque_test;");
    assert(res.nrows == 4);
    assert(res.ncols == 2);

    writefln("Result: %s", res);
}
