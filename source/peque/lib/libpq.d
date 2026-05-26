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

struct pg_conn;
struct pg_result;

alias pg_conn PGconn;
alias pg_result PGresult;


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
        {q{int}, q{PQserverVersion}, q{const(PGconn)* conn}},

        {q{PGresult*}, q{PQexec}, q{PGconn* conn, const(char)* query}},
        {q{PGresult*}, q{PQexecParams}, q{PGconn* conn, const(char)* command, int nParams, const(Oid)* paramTypes, const(char*)* paramValues, const(int)* paramLengths, const(int)* paramFormats, int resultFormat}},
        {q{char*}, q{PQerrorMessage}, q{const(PGconn)* conn}},

        {q{ExecStatusType}, q{PQresultStatus}, q{const(PGresult)* res}},
        {q{char*}, q{PQresStatus}, q{ExecStatusType status}},
        {q{char*}, q{PQresultErrorMessage}, q{const(PGresult)* res}},

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

        // Async send — return 1=ok, 0=fail
        {q{int}, q{PQsendQuery},              q{PGconn* conn, const(char)* query}},
        {q{int}, q{PQsendQueryParams},        q{PGconn* conn, const(char)* command, int nParams, const(Oid)* paramTypes, const(char*)* paramValues, const(int)* paramLengths, const(int)* paramFormats, int resultFormat}},

        // Flush / consume / busy / socket
        {q{int},       q{PQflush},            q{PGconn* conn}},         // 0=done, 1=would block, -1=error
        {q{int},       q{PQsocket},           q{const(PGconn)* conn}},
        {q{int},       q{PQconsumeInput},     q{PGconn* conn}},         // 1=ok, 0=error
        {q{int},       q{PQisBusy},           q{PGconn* conn}},         // 1=busy, 0=result ready
        {q{PGresult*}, q{PQgetResult},        q{PGconn* conn}},

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
