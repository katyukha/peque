/** This module contains postgres type constants
  **/
module peque.pg_type;

import peque.c: Oid;


/** Oids for postgresql types
  **/
enum PGType : Oid {
    // TODO: rename to avoid possible conflicts with libpq
    // Generated for postgres 14.
    // See: tools/fetch_type_oids.sql script

    GUESS = 0,  // Special peque value to indicate that type is not provided

    BOOL = 16,
    BYTEA = 17,
    CHAR = 18,
    NAME = 19,
    INT8 = 20,
    INT2 = 21,
    INT2VECTOR = 22,
    INT4 = 23,
    REGPROC = 24,
    TEXT = 25,
    OID = 26,
    TID = 27,
    XID = 28,
    CID = 29,
    OIDVECTOR = 30,
    JSON = 114,
    XML = 142,
    POINT = 600,
    LSEG = 601,
    PATH = 602,
    BOX = 603,
    POLYGON = 604,
    LINE = 628,
    CIDR = 650,
    FLOAT4 = 700,
    FLOAT8 = 701,
    CIRCLE = 718,
    MACADDR8 = 774,
    MONEY = 790,
    MACADDR = 829,
    INET = 869,
    ACLITEM = 1033,
    BPCHAR = 1042,
    VARCHAR = 1043,
    DATE = 1082,
    TIME = 1083,
    TIMESTAMP = 1114,
    TIMESTAMPTZ = 1184,
    INTERVAL = 1186,
    TIMETZ = 1266,
    BIT = 1560,
    VARBIT = 1562,
    NUMERIC = 1700,
    REFCURSOR = 1790,
    REGPROCEDURE = 2202,
    REGOPER = 2203,
    REGOPERATOR = 2204,
    REGCLASS = 2205,
    REGTYPE = 2206,
    UUID = 2950,
    TXID_SNAPSHOT = 2970,
    TSVECTOR = 3614,
    TSQUERY = 3615,
    GTSVECTOR = 3642,
    REGCONFIG = 3734,
    REGDICTIONARY = 3769,
    JSONB = 3802,
    JSONPATH = 4072,
    REGNAMESPACE = 4089,
    REGROLE = 4096,
    REGCOLLATION = 4191,
    XID8 = 5069
}
