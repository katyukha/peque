module peque.result;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;
private import std.conv;

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

    /// Return status of last executed command;
    string cmdStatus() @trusted {
        return PQcmdStatus(_result._pg_result).fromStringz.idup;
    }

    /// Return number of rows affected by SQL command
    long cmdTuples() @trusted {
        auto res = PQcmdTuples(_result._pg_result).fromStringz;
        if (res && res.length > 0)
            return res.to!long;
        return 0;
    }

}
