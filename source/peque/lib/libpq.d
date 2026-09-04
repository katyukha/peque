/* D bindings for libpq (PostgreSQL client library).
 * Translated from the PostgreSQL libpq C headers using BindBC codegen
 * for dynamic loading support.
 *
 * PostgreSQL is Copyright © 1996-2024 The PostgreSQL Global Development Group.
 * PostgreSQL is licensed under the PostgreSQL License
 * (see https://www.postgresql.org/about/licence/).
 */
module peque.lib.libpq;

// Added here to make available usage of FILE and time_t
public import core.stdc.time;
public import core.stdc.stdio;

private import bindbc.common.codegen: joinFnBinds, FnBind;



//postgres_ext.h
alias uint Oid;

// ConnStatusType
enum
{
    CONNECTION_OK = 0,
    CONNECTION_BAD = 1,
    CONNECTION_STARTED = 2,
    CONNECTION_MADE = 3,
    CONNECTION_AWAITING_RESPONSE = 4,
    CONNECTION_AUTH_OK = 5,
    CONNECTION_SETENV = 6,
    CONNECTION_SSL_STARTUP = 7,
    CONNECTION_NEEDED = 8
};
alias int ConnStatusType;

// PGTransactionStatusType — the connection's transaction state.
// INTRANS/INERROR both mean a transaction block is open; INERROR additionally
// means it has already failed and only ROLLBACK is accepted.
enum
{
    PQTRANS_IDLE = 0,      // connection idle, no transaction open
    PQTRANS_ACTIVE = 1,    // a command is in progress
    PQTRANS_INTRANS = 2,   // idle, inside a valid transaction block
    PQTRANS_INERROR = 3,   // idle, inside a FAILED transaction block
    PQTRANS_UNKNOWN = 4    // cannot determine (bad connection)
}
alias int PGTransactionStatusType;

// ExecStatusType
enum
{
    PGRES_EMPTY_QUERY = 0,
    PGRES_COMMAND_OK = 1,
    PGRES_TUPLES_OK = 2,
    PGRES_COPY_OUT = 3,
    PGRES_COPY_IN = 4,
    PGRES_BAD_RESPONSE = 5,
    PGRES_NONFATAL_ERROR = 6,
    PGRES_FATAL_ERROR = 7,
    PGRES_COPY_BOTH = 8,
    PGRES_SINGLE_TUPLE = 9
}
alias int ExecStatusType;

/** Field codes for PQresultErrorField, from postgres_ext.h.
  *
  * All of them are bound, not only the ones peque currently reads: they are
  * single-character codes and adding the rest later would be pure churn.
  *
  * PG_DIAG_SEVERITY_NONLOCALIZED requires PostgreSQL 9.6+; on older servers
  * PQresultErrorField simply returns null for it.
  **/
enum PG_DIAG_SEVERITY              = 'S';
enum PG_DIAG_SEVERITY_NONLOCALIZED = 'V';
enum PG_DIAG_SQLSTATE              = 'C';
enum PG_DIAG_MESSAGE_PRIMARY       = 'M';
enum PG_DIAG_MESSAGE_DETAIL        = 'D';
enum PG_DIAG_MESSAGE_HINT          = 'H';
enum PG_DIAG_STATEMENT_POSITION    = 'P';
enum PG_DIAG_INTERNAL_POSITION     = 'p';
enum PG_DIAG_INTERNAL_QUERY        = 'q';
enum PG_DIAG_CONTEXT               = 'W';
enum PG_DIAG_SCHEMA_NAME           = 's';
enum PG_DIAG_TABLE_NAME            = 't';
enum PG_DIAG_COLUMN_NAME           = 'c';
enum PG_DIAG_DATATYPE_NAME         = 'd';
enum PG_DIAG_CONSTRAINT_NAME       = 'n';
enum PG_DIAG_SOURCE_FILE           = 'F';
enum PG_DIAG_SOURCE_LINE           = 'L';
enum PG_DIAG_SOURCE_FUNCTION       = 'R';

struct pg_conn;
struct pg_result;

alias pg_conn PGconn;
alias pg_result PGresult;

/* PGnotify — notification message received via LISTEN/NOTIFY.
 * Layout must match libpq-fe.h exactly, including the internal `next` field.
 * Instances are heap-allocated by libpq (returned by PQnotifies) and must be
 * released with PQfreemem.
 */
struct pgNotify {
    char* relname;      // notification channel name
    int   be_pid;       // process ID of the notifying server backend
    char* extra;        // notification payload string
    // Field below is private to libpq; never touch it.
    pgNotify* next;     // list link (libpq internal)
}
alias pgNotify PGnotify;


enum staticBinding = (){
	version(BindBC_Static)      return true;
	else version(PequeStatic) return true;
	else return false;
}();

mixin(joinFnBinds!staticBinding((){
    FnBind[] ret = [
        {q{PGconn*}, q{PQconnectdb}, q{const(char)* conninfo}},
        {q{PGconn*}, q{PQconnectdbParams}, q{const(char*)* keywords, const(char*)* values, int expand_dbname}},
        {q{void}, q{PQfinish}, q{PGconn* conn}},

        {q{ConnStatusType}, q{PQstatus}, q{const(PGconn)* conn}},
        {q{PGTransactionStatusType}, q{PQtransactionStatus}, q{const(PGconn)* conn}},
        {q{int}, q{PQserverVersion}, q{const(PGconn)* conn}},

        {q{PGresult*}, q{PQexec}, q{PGconn* conn, const(char)* query}},
        {q{PGresult*}, q{PQexecParams}, q{PGconn* conn, const(char)* command, int nParams, const(Oid)* paramTypes, const(char*)* paramValues, const(int)* paramLengths, const(int)* paramFormats, int resultFormat}},
        {q{char*}, q{PQerrorMessage}, q{const(PGconn)* conn}},

        {q{ExecStatusType}, q{PQresultStatus}, q{const(PGresult)* res}},
        {q{char*}, q{PQresStatus}, q{ExecStatusType status}},
        {q{char*}, q{PQresultErrorMessage}, q{const(PGresult)* res}},
        {q{char*}, q{PQresultErrorField}, q{const(PGresult)* res, int fieldcode}},

        {q{int}, q{PQntuples}, q{const(PGresult)* res}},
        {q{int}, q{PQnfields}, q{const(PGresult)* res}},
        {q{char*}, q{PQfname}, q{const(PGresult)* res, int field_num}},
        {q{int}, q{PQfnumber}, q{const(PGresult)* res, const(char)* field_name}},
        {q{int}, q{PQfformat}, q{const(PGresult)* res, int field_num}},
        {q{Oid}, q{PQftype}, q{const(PGresult)* res, int field_num}},
        {q{char*}, q{PQcmdStatus}, q{PGresult* res}},
        {q{char*}, q{PQcmdTuples}, q{PGresult* res}},
        {q{char*}, q{PQgetvalue}, q{const(PGresult)* res, int tup_num, int field_num}},
        {q{int}, q{PQgetlength}, q{const(PGresult)* res, int tup_num, int field_num}},
        {q{int}, q{PQgetisnull}, q{const(PGresult)* res, int tup_num, int field_num}},
        {q{int}, q{PQnparams}, q{const(PGresult)* res}},
        {q{void}, q{PQclear}, q{PGresult* res}},


        {q{size_t}, q{PQescapeStringConn}, q{PGconn* conn, char* to, const(char)* from, size_t length, int* error}},
        // Returns a libpq-malloc'd buffer (must be released with PQfreemem), or null on error
        {q{char*}, q{PQescapeIdentifier}, q{PGconn* conn, const(char)* str, size_t length}},

        // Async send — return 1=ok, 0=fail
        {q{int}, q{PQsendQuery},              q{PGconn* conn, const(char)* query}},
        {q{int}, q{PQsendQueryParams},        q{PGconn* conn, const(char)* command, int nParams, const(Oid)* paramTypes, const(char*)* paramValues, const(int)* paramLengths, const(int)* paramFormats, int resultFormat}},

        // Flush / consume / busy / socket
        {q{int},       q{PQflush},            q{PGconn* conn}},         // 0=done, 1=would block, -1=error
        {q{int},       q{PQsocket},           q{const(PGconn)* conn}},
        {q{int},       q{PQconsumeInput},     q{PGconn* conn}},         // 1=ok, 0=error
        {q{int},       q{PQisBusy},           q{PGconn* conn}},         // 1=busy, 0=result ready
        {q{PGresult*}, q{PQgetResult},        q{PGconn* conn}},

        // LISTEN/NOTIFY — PQnotifies pops one buffered notification (null when drained);
        // each returned PGnotify* must be released with PQfreemem
        {q{PGnotify*}, q{PQnotifies},         q{PGconn* conn}},
        {q{void},      q{PQfreemem},          q{void* ptr}},

        // COPY sub-protocol — bound only to abort/drain an unexpected COPY
        // so the connection stays usable (peque does not implement COPY).
        // PQgetCopyData: >0=row length (buffer must be PQfreemem'd),
        //                0=no data yet (async), -1=copy done, -2=error
        // PQputCopyEnd:  1=ok, 0=would block (retry), -1=error
        {q{int}, q{PQgetCopyData}, q{PGconn* conn, char** buffer, int async}},
        {q{int}, q{PQputCopyEnd},  q{PGconn* conn, const(char)* errormsg}},

        // Non-blocking mode
        {q{int}, q{PQsetnonblocking},         q{PGconn* conn, int arg}},
        {q{int}, q{PQisnonblocking},          q{const(PGconn)* conn}},

        // Prepared statements (async path) — return 1=ok, 0=fail
        {q{int},       q{PQsendPrepare},          q{PGconn* conn, const(char)* stmtName, const(char)* query, int nParams, const(Oid)* paramTypes}},
        {q{int},       q{PQsendQueryPrepared},    q{PGconn* conn, const(char)* stmtName, int nParams, const(char*)* paramValues, const(int)* paramLengths, const(int)* paramFormats, int resultFormat}},
        {q{int},       q{PQsendDescribePrepared}, q{PGconn* conn, const(char)* stmtName}},
        {q{PGresult*}, q{PQdescribePrepared},     q{PGconn* conn, const(char)* stmtName}},
    ];

    return ret;
}()));
