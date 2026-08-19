/** peque's exception hierarchy.
  *
  * Organised on one axis: whose fault is it, and where did it happen.
  *
  * ---
  * PequeException                  root — never thrown directly
  * ├── ConnectionError             the link is unusable
  * ├── NotSupportedError           peque will not do this, in any context
  * ├── ConversionError             a value could not be converted, either direction
  * ├── QueryError                  category — scoped to running a query
  * │   ├── QueryClientError        your call is wrong
  * │   │   └── QueryEscapingError  …an identifier/JSON key that cannot be escaped
  * │   └── QueryServerError        PostgreSQL rejected it — carries SQLSTATE
  * │       ├── IntegrityError      SQLSTATE class 23
  * │       └── SerializationError  SQLSTATE class 40
  * └── ResultError                 the result has no such row or column
  *     ├── RowNotExistsError
  *     └── ColNotExistsError
  * ---
  *
  * Exceptions carry structured fields, not just a message: acting on an error
  * should never require parsing its text. Server messages are localised by
  * `lc_messages`, which a non-superuser cannot override, so text matching is
  * unsound.
  **/
module peque.exception;

import std.exception;
import std.format: format;

@safe:

/// Root of every peque exception. Never thrown directly.
class PequeException : Exception {
    mixin basicExceptionCtors;
}


// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/** The connection is unusable.
  *
  * Connect-time failures, and later transport failures such as `poll()` on the
  * socket or libpq refusing to send/consume. Not a query error — the statement
  * may have been perfectly valid.
  **/
class ConnectionError : PequeException {
    mixin basicExceptionCtors;
}


// ---------------------------------------------------------------------------
// Unsupported
// ---------------------------------------------------------------------------

/** peque will not do this, in any context.
  *
  * Unlike QueryClientError there is no way to call it correctly — the fix is a
  * different approach. Examples: COPY TO/FROM STDOUT, nested `exists!()`,
  * `waitNotifications` on a WaitStrategy with no timed overload.
  **/
class NotSupportedError : PequeException {
    mixin basicExceptionCtors;
}


// ---------------------------------------------------------------------------
// Conversion — independent of connection, query and result
// ---------------------------------------------------------------------------

/** A value could not be converted between a D type and its PostgreSQL
  * representation, in either direction.
  *
  * Independent of any connection, query or result — `peque.converter` can be
  * used on its own.
  **/
class ConversionError : PequeException {
    /// Type being converted FROM: the PostgreSQL type when reading a result,
    /// the D type when sending a parameter. May be empty.
    string sourceType;
    /// Type being converted TO — the reverse of sourceType. May be empty.
    string targetType;
    /// The offending value as text, when it was available and safe to include.
    /// Empty for parameters: those are caller data and may be secrets.
    string value;

    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }

    this(string msg, string sourceType, string targetType, string value = "",
         Throwable nextInChain = null,
         string file = __FILE__, size_t line = __LINE__) @safe pure nothrow {
        super(msg, file, line, nextInChain);
        this.sourceType = sourceType;
        this.targetType = targetType;
        this.value      = value;
    }
}


// ---------------------------------------------------------------------------
// Result access
// ---------------------------------------------------------------------------

/// The result has no such row or column. Category — never thrown directly.
class ResultError : PequeException {
    mixin basicExceptionCtors;
}

/// A row index outside 0 .. ntuples.
class RowNotExistsError : ResultError {
    /// Index that was asked for.
    long rowIndex = -1;
    /// Number of rows the result actually has.
    long ntuples = -1;

    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }

    this(long rowIndex, long ntuples, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super(format!"Row %d does not exist: the result has %d row(s)."(rowIndex, ntuples),
              file, line);
        this.rowIndex = rowIndex;
        this.ntuples  = ntuples;
    }
}

/// A column name or index that the result does not have.
class ColNotExistsError : ResultError {
    /// Column name that was asked for, when the lookup was by name.
    string colName;
    /// Column index that was asked for, or -1 when the lookup was by name.
    long colIndex = -1;
    /// Number of columns the result actually has.
    long nfields = -1;
    /// Names of the columns that ARE present, so a caller can report or match.
    string[] available;

    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }

    this(string colName, long nfields, string[] available,
         string file = __FILE__, size_t line = __LINE__) @safe pure {
        super(format!"Column \"%s\" does not exist. Available: %-(%s, %)"(colName, available),
              file, line);
        this.colName   = colName;
        this.nfields   = nfields;
        this.available = available;
    }

    this(long colIndex, long nfields, string file = __FILE__, size_t line = __LINE__) @safe pure {
        super(format!"Column %d does not exist: the result has %d column(s)."(colIndex, nfields),
              file, line);
        this.colIndex = colIndex;
        this.nfields  = nfields;
    }
}


// ---------------------------------------------------------------------------
// Query
// ---------------------------------------------------------------------------

/// Something went wrong running a query. Category — never thrown directly.
class QueryError : PequeException {
    mixin basicExceptionCtors;
}

/** The call was wrong: peque rejected it before, or instead of, sending it.
  *
  * Bad arguments, a malformed relation path, a negative limit, a value that
  * cannot be sent. Always a programming error — the fix is in the caller.
  **/
class QueryClientError : QueryError {
    mixin basicExceptionCtors;
}

/// An identifier or JSON key that cannot be safely escaped.
class QueryEscapingError : QueryClientError {
    mixin basicExceptionCtors;
}

/** PostgreSQL rejected the statement.
  *
  * Carries the backend's structured diagnostics, captured when the exception is
  * built — the PGresult is freed as the stack unwinds, so reading them later is
  * impossible and message text is the only alternative. Since server messages
  * are localised by `lc_messages` (which a non-superuser cannot override),
  * `sqlstate` is the only locale-independent way to classify a failure.
  *
  * Fields the server did not supply are empty strings. That is common and
  * expected: a not-null violation reports `columnName` but no constraint, while
  * unique and foreign-key violations report `constraintName` but no column —
  * the offending columns appear only inside the localised DETAIL text, which
  * peque deliberately does not parse.
  **/
class QueryServerError : QueryError {
    /// Five-character SQLSTATE, e.g. "23505". Populated for every error the
    /// server reports; empty only if its response could not be parsed at all.
    string sqlstate;
    string constraintName;
    string columnName;
    string tableName;
    string schemaName;
    string datatypeName;
    string messagePrimary;
    string messageDetail;
    string messageHint;
    /// 1-based index into the statement text, as a string. Empty when absent.
    string statementPosition;

    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }

    /** True when re-running the statement could plausibly succeed.
      *
      * A predicate rather than a subclass: retry-ability cuts across SQLSTATE
      * classes, so no single-inheritance tree can express it.
      *
      * Classes 40 (serialization failure, deadlock) and 55P03 (lock not
      * available) can be retried on the same connection. Class 08 means the
      * connection itself is gone — retry only after obtaining a fresh one.
      *
      * Codes whose outcome is genuinely unknown are deliberately excluded:
      * 40003 (statement_completion_unknown) may have committed, and 57014
      * (query_canceled) is a cancellation the caller usually requested.
      **/
    bool isRetriable() const @safe pure nothrow {
        switch (sqlstate) {
            // Class 40 — the transaction rolled back and can be replayed.
            // 40003 (statement_completion_unknown) is excluded: the statement
            // may already have committed.
            case "40000": case "40001": case "40002": case "40P01":
            case "55P03":            // lock_not_available
            // Server going away or not yet accepting connections: retry once a
            // fresh connection is available.
            case "57P01": case "57P02": case "57P03":
            case "08000": case "08001": case "08003":
            case "08004": case "08006":
                return true;
            default:
                return false;
        }
    }

    /// SQLSTATE class — the first two characters, e.g. "23".
    string sqlstateClass() const @safe pure nothrow {
        return sqlstate.length >= 2 ? sqlstate[0 .. 2] : "";
    }
}

/** SQLSTATE class 23 sub-kinds.
  *
  * `other` covers any class-23 code peque does not name, so an unrecognised
  * code still arrives as an IntegrityError rather than falling back to the base.
  **/
enum IntegrityKind {
    notNull,     /// 23502
    foreignKey,  /// 23503
    unique,      /// 23505
    check,       /// 23514
    exclusion,   /// 23P01
    restrict,    /// 23001
    other,       /// any other class-23 code
}

/// SQLSTATE class 23 — integrity_constraint_violation.
class IntegrityError : QueryServerError {
    /// Which kind of constraint was violated.
    IntegrityKind kind = IntegrityKind.other;

    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }
}

/** SQLSTATE class 40 — transaction_rollback.
  *
  * Usually retriable, but check `isRetriable()`: 40003
  * (statement_completion_unknown) means the statement may already have
  * committed, so replaying it could apply the change twice.
  **/
class SerializationError : QueryServerError {
    this(string msg, string file = __FILE__, size_t line = __LINE__,
         Throwable nextInChain = null) @safe pure nothrow {
        super(msg, file, line, nextInChain);
    }

    this(string msg, Throwable nextInChain) @safe pure nothrow {
        super(msg, nextInChain);
    }
}
