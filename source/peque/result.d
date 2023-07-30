module peque.result;

private import std.typecons;
private import std.exception: enforce;
private import std.format: format;
private import std.string: toStringz, fromStringz;
private import std.algorithm: canFind;
private import std.conv;
private import std.datetime;

private import std.traits:
    isSomeString, isScalarType, isIntegral, isBoolean, isFloatingPoint;

private import peque.c;
private import peque.pg_type;
private import peque.exception;
private import peque.converter;


package(peque) enum ColFormat: int {
    text = 0,
    binary = 1,
}


/// Refcounted wrapper for PGresult to be used as ResultInternal.
private @safe struct ResultInternalData {
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


/** This struct represents value of single CELL in postgresql result
  **/
@safe struct ResultValue {
    private ResultInternal _result;
    private int _row_number;
    private int _col_number;

    @disable this(this);

    private this(ResultInternal result, in int row_number, in int col_number) {
        _result = result;
        _row_number = row_number;
        _col_number = col_number;
    }

    /// Check if value is null or not
    bool isNull() @trusted {
        /* From postres docs:
         * This function returns 1 if the field is null and 0
         * if it contains a non-null value.
         * (Note that PQgetvalue will return an empty string,
         * not a null pointer, for a null field.)
         */
        if (PQgetisnull(_result._pg_result, _row_number, _col_number) == 1)
            return true;
        return false;
    }

    /// Returns actual length of field's value in bytes
    auto getLength() @trusted {
        return PQgetlength(_result._pg_result, _row_number, _col_number);
    }

    /// Retruns type of field of this cell.
    PGType getType() @trusted {
        return cast(PGType)PQftype(_result._pg_result, _col_number);
    }

    /// Returns column format (binary or text)
    ColFormat getFormat() @trusted {
        return cast(ColFormat)PQfformat(_result._pg_result, _col_number);
    }

    /// Convert value to string representation
    T get(T)() {
        enforce!ConversionError(
            !isNull,
            "Cannot read null value as string.");
        enforce!ConversionError(
            getFormat == ColFormat.text,
            "At the moment, peque supports only deserialization of postgres text types.");

        // get original postgresql value
        scope const char* val = _result.borrow!((auto ref res) @trusted {
            return PQgetvalue(
                res._pg_result,
                _row_number,
                _col_number);
        });
        // Return converted value
        return convertTextTypeToD!T(val, getLength, getType);
    }
}

/** This struct represents result of query and allows to fetch data received
  * from postgresql
  **/
@safe struct Result {
    private ResultInternal _result;

    package(peque) this(PGresult* result) {
        _result = ResultInternal(result);
    }

    void opAssign(Result res) {
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

    /// Return number of rows (tuples) fetched.
    auto ntuples() @trusted { return PQntuples(_result._pg_result); }

    /// Return number of columns (fields) fetched.
    auto nfields() @trusted { return PQnfields(_result._pg_result); }

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

    /// Return name of column associated with provided colum index in result
    Nullable!string fieldName(in int index) @trusted {
        auto res = PQfname(_result._pg_result, index);
        if (res)
            return res.fromStringz.idup.nullable;
        return Nullable!string.init;
    }

    /// Return number of column associated with provided column name in result
    Nullable!int fieldNumber(in string name) @trusted {
        auto res = PQfnumber(_result._pg_result, name.toStringz);
        return res >=0 ? res.nullable : Nullable!int.init;
    }

    /** Get value for cell specified by row_number and col_number.
      * Both, row_number and col_number start from 0.
      *
      * Params:
      *     row_number = index of row to get value for
      *     col_number = index of column to get value for
      *
      **/
    auto getValue(in int row_number, in int col_number) {
        enforce!RowNotExistsError(
            row_number >= 0 && row_number < ntuples,
            "Row %s does not exists in result!".format(row_number));
        enforce!ColNotExistsError(
            col_number >= 0 && col_number < ntuples,
            "Row %s does not exists in result!".format(row_number));
        return ResultValue(_result, row_number, col_number);
    }
}
