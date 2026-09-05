/**
  * This module contains constants for Postgres Oids for postgres types
  * and some unitities to work with postgres types information.
  *
  * This module is automatcially by `tools/generate_pg_types.d` script.
  **/
module peque.pg_type;

private import peque.lib.libpq: Oid;


/**
  * Mapping for Postgres types and Oids.
  * See docs: https://www.postgresql.org/docs/current/catalog-pg-type.html
  *
  * Generated automatcially by `tools/generate_pg_types.d` script.
  **/
enum PGType : Oid {
    GUESS = 0,
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
    XID8 = 5069,
    _BOOL = 1000,
    _BYTEA = 1001,
    _CHAR = 1002,
    _NAME = 1003,
    _INT8 = 1016,
    _INT2 = 1005,
    _INT2VECTOR = 1006,
    _INT4 = 1007,
    _REGPROC = 1008,
    _TEXT = 1009,
    _OID = 1028,
    _TID = 1010,
    _XID = 1011,
    _CID = 1012,
    _OIDVECTOR = 1013,
    _JSON = 199,
    _XML = 143,
    _POINT = 1017,
    _LSEG = 1018,
    _PATH = 1019,
    _BOX = 1020,
    _POLYGON = 1027,
    _LINE = 629,
    _CIDR = 651,
    _FLOAT4 = 1021,
    _FLOAT8 = 1022,
    _CIRCLE = 719,
    _MACADDR8 = 775,
    _MONEY = 791,
    _MACADDR = 1040,
    _INET = 1041,
    _ACLITEM = 1034,
    _BPCHAR = 1014,
    _VARCHAR = 1015,
    _DATE = 1182,
    _TIME = 1183,
    _TIMESTAMP = 1115,
    _TIMESTAMPTZ = 1185,
    _INTERVAL = 1187,
    _TIMETZ = 1270,
    _BIT = 1561,
    _VARBIT = 1563,
    _NUMERIC = 1231,
    _REFCURSOR = 2201,
    _REGPROCEDURE = 2207,
    _REGOPER = 2208,
    _REGOPERATOR = 2209,
    _REGCLASS = 2210,
    _REGTYPE = 2211,
    _UUID = 2951,
    _TXID_SNAPSHOT = 2949,
    _TSVECTOR = 3643,
    _TSQUERY = 3645,
    _GTSVECTOR = 3644,
    _REGCONFIG = 3735,
    _REGDICTIONARY = 3770,
    _JSONB = 3807,
    _JSONPATH = 4073,
    _REGNAMESPACE = 4090,
    _REGROLE = 4097,
    _REGCOLLATION = 4192,
    _XID8 = 271,
}


/** This struct represents info about postgres type
  **/
immutable struct PGTypeInfo {
    PGType type;
    PGType array_type;
}


/** Return extra info about postgres type
  *
  * Not a `final switch`: OIDs read from a result are cast straight from
  * PQftype, so a user-defined type, an extension type (PostGIS geometry,
  * hstore) or a type from a newer PostgreSQL is a PGType value that is not a
  * member here. A `final switch` answers that with SwitchError, and under
  * `-release` with SIGILL. An unknown type has no known array type, so it
  * reports GUESS — the enum's own "unspecified" sentinel, which is OID 0 and
  * tells the server to infer.
  *
  * Params:
  *     type = PGType to get extra info for
  * Returns: PGTypeInfo struct that represents extra info about this PGType
  **/
PGTypeInfo getPgTypeInfo(in PGType type) @safe pure nothrow {
    with(PGType) switch(type) {
        case GUESS: return PGTypeInfo(GUESS, GUESS);
        case BOOL: return PGTypeInfo(BOOL, _BOOL);
        case BYTEA: return PGTypeInfo(BYTEA, _BYTEA);
        case CHAR: return PGTypeInfo(CHAR, _CHAR);
        case NAME: return PGTypeInfo(NAME, _NAME);
        case INT8: return PGTypeInfo(INT8, _INT8);
        case INT2: return PGTypeInfo(INT2, _INT2);
        case INT2VECTOR: return PGTypeInfo(INT2VECTOR, _INT2VECTOR);
        case INT4: return PGTypeInfo(INT4, _INT4);
        case REGPROC: return PGTypeInfo(REGPROC, _REGPROC);
        case TEXT: return PGTypeInfo(TEXT, _TEXT);
        case OID: return PGTypeInfo(OID, _OID);
        case TID: return PGTypeInfo(TID, _TID);
        case XID: return PGTypeInfo(XID, _XID);
        case CID: return PGTypeInfo(CID, _CID);
        case OIDVECTOR: return PGTypeInfo(OIDVECTOR, _OIDVECTOR);
        case JSON: return PGTypeInfo(JSON, _JSON);
        case XML: return PGTypeInfo(XML, _XML);
        case POINT: return PGTypeInfo(POINT, _POINT);
        case LSEG: return PGTypeInfo(LSEG, _LSEG);
        case PATH: return PGTypeInfo(PATH, _PATH);
        case BOX: return PGTypeInfo(BOX, _BOX);
        case POLYGON: return PGTypeInfo(POLYGON, _POLYGON);
        case LINE: return PGTypeInfo(LINE, _LINE);
        case CIDR: return PGTypeInfo(CIDR, _CIDR);
        case FLOAT4: return PGTypeInfo(FLOAT4, _FLOAT4);
        case FLOAT8: return PGTypeInfo(FLOAT8, _FLOAT8);
        case CIRCLE: return PGTypeInfo(CIRCLE, _CIRCLE);
        case MACADDR8: return PGTypeInfo(MACADDR8, _MACADDR8);
        case MONEY: return PGTypeInfo(MONEY, _MONEY);
        case MACADDR: return PGTypeInfo(MACADDR, _MACADDR);
        case INET: return PGTypeInfo(INET, _INET);
        case ACLITEM: return PGTypeInfo(ACLITEM, _ACLITEM);
        case BPCHAR: return PGTypeInfo(BPCHAR, _BPCHAR);
        case VARCHAR: return PGTypeInfo(VARCHAR, _VARCHAR);
        case DATE: return PGTypeInfo(DATE, _DATE);
        case TIME: return PGTypeInfo(TIME, _TIME);
        case TIMESTAMP: return PGTypeInfo(TIMESTAMP, _TIMESTAMP);
        case TIMESTAMPTZ: return PGTypeInfo(TIMESTAMPTZ, _TIMESTAMPTZ);
        case INTERVAL: return PGTypeInfo(INTERVAL, _INTERVAL);
        case TIMETZ: return PGTypeInfo(TIMETZ, _TIMETZ);
        case BIT: return PGTypeInfo(BIT, _BIT);
        case VARBIT: return PGTypeInfo(VARBIT, _VARBIT);
        case NUMERIC: return PGTypeInfo(NUMERIC, _NUMERIC);
        case REFCURSOR: return PGTypeInfo(REFCURSOR, _REFCURSOR);
        case REGPROCEDURE: return PGTypeInfo(REGPROCEDURE, _REGPROCEDURE);
        case REGOPER: return PGTypeInfo(REGOPER, _REGOPER);
        case REGOPERATOR: return PGTypeInfo(REGOPERATOR, _REGOPERATOR);
        case REGCLASS: return PGTypeInfo(REGCLASS, _REGCLASS);
        case REGTYPE: return PGTypeInfo(REGTYPE, _REGTYPE);
        case UUID: return PGTypeInfo(UUID, _UUID);
        case TXID_SNAPSHOT: return PGTypeInfo(TXID_SNAPSHOT, _TXID_SNAPSHOT);
        case TSVECTOR: return PGTypeInfo(TSVECTOR, _TSVECTOR);
        case TSQUERY: return PGTypeInfo(TSQUERY, _TSQUERY);
        case GTSVECTOR: return PGTypeInfo(GTSVECTOR, _GTSVECTOR);
        case REGCONFIG: return PGTypeInfo(REGCONFIG, _REGCONFIG);
        case REGDICTIONARY: return PGTypeInfo(REGDICTIONARY, _REGDICTIONARY);
        case JSONB: return PGTypeInfo(JSONB, _JSONB);
        case JSONPATH: return PGTypeInfo(JSONPATH, _JSONPATH);
        case REGNAMESPACE: return PGTypeInfo(REGNAMESPACE, _REGNAMESPACE);
        case REGROLE: return PGTypeInfo(REGROLE, _REGROLE);
        case REGCOLLATION: return PGTypeInfo(REGCOLLATION, _REGCOLLATION);
        case XID8: return PGTypeInfo(XID8, _XID8);
        case _BOOL: return PGTypeInfo(_BOOL, GUESS);
        case _BYTEA: return PGTypeInfo(_BYTEA, GUESS);
        case _CHAR: return PGTypeInfo(_CHAR, GUESS);
        case _NAME: return PGTypeInfo(_NAME, GUESS);
        case _INT8: return PGTypeInfo(_INT8, GUESS);
        case _INT2: return PGTypeInfo(_INT2, GUESS);
        case _INT2VECTOR: return PGTypeInfo(_INT2VECTOR, GUESS);
        case _INT4: return PGTypeInfo(_INT4, GUESS);
        case _REGPROC: return PGTypeInfo(_REGPROC, GUESS);
        case _TEXT: return PGTypeInfo(_TEXT, GUESS);
        case _OID: return PGTypeInfo(_OID, GUESS);
        case _TID: return PGTypeInfo(_TID, GUESS);
        case _XID: return PGTypeInfo(_XID, GUESS);
        case _CID: return PGTypeInfo(_CID, GUESS);
        case _OIDVECTOR: return PGTypeInfo(_OIDVECTOR, GUESS);
        case _JSON: return PGTypeInfo(_JSON, GUESS);
        case _XML: return PGTypeInfo(_XML, GUESS);
        case _POINT: return PGTypeInfo(_POINT, GUESS);
        case _LSEG: return PGTypeInfo(_LSEG, GUESS);
        case _PATH: return PGTypeInfo(_PATH, GUESS);
        case _BOX: return PGTypeInfo(_BOX, GUESS);
        case _POLYGON: return PGTypeInfo(_POLYGON, GUESS);
        case _LINE: return PGTypeInfo(_LINE, GUESS);
        case _CIDR: return PGTypeInfo(_CIDR, GUESS);
        case _FLOAT4: return PGTypeInfo(_FLOAT4, GUESS);
        case _FLOAT8: return PGTypeInfo(_FLOAT8, GUESS);
        case _CIRCLE: return PGTypeInfo(_CIRCLE, GUESS);
        case _MACADDR8: return PGTypeInfo(_MACADDR8, GUESS);
        case _MONEY: return PGTypeInfo(_MONEY, GUESS);
        case _MACADDR: return PGTypeInfo(_MACADDR, GUESS);
        case _INET: return PGTypeInfo(_INET, GUESS);
        case _ACLITEM: return PGTypeInfo(_ACLITEM, GUESS);
        case _BPCHAR: return PGTypeInfo(_BPCHAR, GUESS);
        case _VARCHAR: return PGTypeInfo(_VARCHAR, GUESS);
        case _DATE: return PGTypeInfo(_DATE, GUESS);
        case _TIME: return PGTypeInfo(_TIME, GUESS);
        case _TIMESTAMP: return PGTypeInfo(_TIMESTAMP, GUESS);
        case _TIMESTAMPTZ: return PGTypeInfo(_TIMESTAMPTZ, GUESS);
        case _INTERVAL: return PGTypeInfo(_INTERVAL, GUESS);
        case _TIMETZ: return PGTypeInfo(_TIMETZ, GUESS);
        case _BIT: return PGTypeInfo(_BIT, GUESS);
        case _VARBIT: return PGTypeInfo(_VARBIT, GUESS);
        case _NUMERIC: return PGTypeInfo(_NUMERIC, GUESS);
        case _REFCURSOR: return PGTypeInfo(_REFCURSOR, GUESS);
        case _REGPROCEDURE: return PGTypeInfo(_REGPROCEDURE, GUESS);
        case _REGOPER: return PGTypeInfo(_REGOPER, GUESS);
        case _REGOPERATOR: return PGTypeInfo(_REGOPERATOR, GUESS);
        case _REGCLASS: return PGTypeInfo(_REGCLASS, GUESS);
        case _REGTYPE: return PGTypeInfo(_REGTYPE, GUESS);
        case _UUID: return PGTypeInfo(_UUID, GUESS);
        case _TXID_SNAPSHOT: return PGTypeInfo(_TXID_SNAPSHOT, GUESS);
        case _TSVECTOR: return PGTypeInfo(_TSVECTOR, GUESS);
        case _TSQUERY: return PGTypeInfo(_TSQUERY, GUESS);
        case _GTSVECTOR: return PGTypeInfo(_GTSVECTOR, GUESS);
        case _REGCONFIG: return PGTypeInfo(_REGCONFIG, GUESS);
        case _REGDICTIONARY: return PGTypeInfo(_REGDICTIONARY, GUESS);
        case _JSONB: return PGTypeInfo(_JSONB, GUESS);
        case _JSONPATH: return PGTypeInfo(_JSONPATH, GUESS);
        case _REGNAMESPACE: return PGTypeInfo(_REGNAMESPACE, GUESS);
        case _REGROLE: return PGTypeInfo(_REGROLE, GUESS);
        case _REGCOLLATION: return PGTypeInfo(_REGCOLLATION, GUESS);
        case _XID8: return PGTypeInfo(_XID8, GUESS);
        default: return PGTypeInfo(type, GUESS);
    }
}


/** Name of a PGType, as a jump table.
  *
  * `std.conv.to!string` on an enum falls back to std.format's generic
  * machinery, which instantiates a formatter over every member of this enum
  * and costs ~80ms of compile time in any build that touches a PGValue. This
  * answers the same question for nothing, and keeps std.format out of the
  * conversion layer entirely.
  *
  * A plain switch rather than `final switch`: OIDs read from a result come from
  * the SERVER, so a type from a newer PostgreSQL — or an extension type such as
  * PostGIS geometry — is not a member here and must not throw from a path that
  * exists to build a diagnostic.
  **/
string pgTypeName(in PGType type) @safe pure nothrow {
    with(PGType) switch(type) {
        case GUESS: return "GUESS";
        case BOOL: return "BOOL";
        case BYTEA: return "BYTEA";
        case CHAR: return "CHAR";
        case NAME: return "NAME";
        case INT8: return "INT8";
        case INT2: return "INT2";
        case INT2VECTOR: return "INT2VECTOR";
        case INT4: return "INT4";
        case REGPROC: return "REGPROC";
        case TEXT: return "TEXT";
        case OID: return "OID";
        case TID: return "TID";
        case XID: return "XID";
        case CID: return "CID";
        case OIDVECTOR: return "OIDVECTOR";
        case JSON: return "JSON";
        case XML: return "XML";
        case POINT: return "POINT";
        case LSEG: return "LSEG";
        case PATH: return "PATH";
        case BOX: return "BOX";
        case POLYGON: return "POLYGON";
        case LINE: return "LINE";
        case CIDR: return "CIDR";
        case FLOAT4: return "FLOAT4";
        case FLOAT8: return "FLOAT8";
        case CIRCLE: return "CIRCLE";
        case MACADDR8: return "MACADDR8";
        case MONEY: return "MONEY";
        case MACADDR: return "MACADDR";
        case INET: return "INET";
        case ACLITEM: return "ACLITEM";
        case BPCHAR: return "BPCHAR";
        case VARCHAR: return "VARCHAR";
        case DATE: return "DATE";
        case TIME: return "TIME";
        case TIMESTAMP: return "TIMESTAMP";
        case TIMESTAMPTZ: return "TIMESTAMPTZ";
        case INTERVAL: return "INTERVAL";
        case TIMETZ: return "TIMETZ";
        case BIT: return "BIT";
        case VARBIT: return "VARBIT";
        case NUMERIC: return "NUMERIC";
        case REFCURSOR: return "REFCURSOR";
        case REGPROCEDURE: return "REGPROCEDURE";
        case REGOPER: return "REGOPER";
        case REGOPERATOR: return "REGOPERATOR";
        case REGCLASS: return "REGCLASS";
        case REGTYPE: return "REGTYPE";
        case UUID: return "UUID";
        case TXID_SNAPSHOT: return "TXID_SNAPSHOT";
        case TSVECTOR: return "TSVECTOR";
        case TSQUERY: return "TSQUERY";
        case GTSVECTOR: return "GTSVECTOR";
        case REGCONFIG: return "REGCONFIG";
        case REGDICTIONARY: return "REGDICTIONARY";
        case JSONB: return "JSONB";
        case JSONPATH: return "JSONPATH";
        case REGNAMESPACE: return "REGNAMESPACE";
        case REGROLE: return "REGROLE";
        case REGCOLLATION: return "REGCOLLATION";
        case XID8: return "XID8";
        case _BOOL: return "_BOOL";
        case _BYTEA: return "_BYTEA";
        case _CHAR: return "_CHAR";
        case _NAME: return "_NAME";
        case _INT8: return "_INT8";
        case _INT2: return "_INT2";
        case _INT2VECTOR: return "_INT2VECTOR";
        case _INT4: return "_INT4";
        case _REGPROC: return "_REGPROC";
        case _TEXT: return "_TEXT";
        case _OID: return "_OID";
        case _TID: return "_TID";
        case _XID: return "_XID";
        case _CID: return "_CID";
        case _OIDVECTOR: return "_OIDVECTOR";
        case _JSON: return "_JSON";
        case _XML: return "_XML";
        case _POINT: return "_POINT";
        case _LSEG: return "_LSEG";
        case _PATH: return "_PATH";
        case _BOX: return "_BOX";
        case _POLYGON: return "_POLYGON";
        case _LINE: return "_LINE";
        case _CIDR: return "_CIDR";
        case _FLOAT4: return "_FLOAT4";
        case _FLOAT8: return "_FLOAT8";
        case _CIRCLE: return "_CIRCLE";
        case _MACADDR8: return "_MACADDR8";
        case _MONEY: return "_MONEY";
        case _MACADDR: return "_MACADDR";
        case _INET: return "_INET";
        case _ACLITEM: return "_ACLITEM";
        case _BPCHAR: return "_BPCHAR";
        case _VARCHAR: return "_VARCHAR";
        case _DATE: return "_DATE";
        case _TIME: return "_TIME";
        case _TIMESTAMP: return "_TIMESTAMP";
        case _TIMESTAMPTZ: return "_TIMESTAMPTZ";
        case _INTERVAL: return "_INTERVAL";
        case _TIMETZ: return "_TIMETZ";
        case _BIT: return "_BIT";
        case _VARBIT: return "_VARBIT";
        case _NUMERIC: return "_NUMERIC";
        case _REFCURSOR: return "_REFCURSOR";
        case _REGPROCEDURE: return "_REGPROCEDURE";
        case _REGOPER: return "_REGOPER";
        case _REGOPERATOR: return "_REGOPERATOR";
        case _REGCLASS: return "_REGCLASS";
        case _REGTYPE: return "_REGTYPE";
        case _UUID: return "_UUID";
        case _TXID_SNAPSHOT: return "_TXID_SNAPSHOT";
        case _TSVECTOR: return "_TSVECTOR";
        case _TSQUERY: return "_TSQUERY";
        case _GTSVECTOR: return "_GTSVECTOR";
        case _REGCONFIG: return "_REGCONFIG";
        case _REGDICTIONARY: return "_REGDICTIONARY";
        case _JSONB: return "_JSONB";
        case _JSONPATH: return "_JSONPATH";
        case _REGNAMESPACE: return "_REGNAMESPACE";
        case _REGROLE: return "_REGROLE";
        case _REGCOLLATION: return "_REGCOLLATION";
        case _XID8: return "_XID8";
        default: return "UNKNOWN";
    }
}
