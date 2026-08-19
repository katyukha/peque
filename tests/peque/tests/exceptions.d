/** The exception tree's contract: its shape, and the structured payloads that
  * make acting on an error possible without parsing message text.
  **/
module peque.tests.exceptions;

private import std.process: environment;
private import std.exception: assertThrown, collectException;
private import std.algorithm.searching: canFind;

private import peque.connection: Connection;
private import peque.exception;

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

private void setup(ref Connection c) {
    c.exec(`DROP TABLE IF EXISTS exc_child`);
    c.exec(`DROP TABLE IF EXISTS exc_parent`);
    c.exec(`CREATE TABLE exc_parent (
                id  int PRIMARY KEY,
                tag text UNIQUE,
                req text NOT NULL,
                n   int CHECK (n > 0))`);
    c.exec(`CREATE TABLE exc_child (
                id int PRIMARY KEY,
                parent_id int REFERENCES exc_parent(id))`);
    c.exec(`INSERT INTO exc_parent VALUES (1, 'a', 'x', 1)`);
}


// ---------------------------------------------------------------------------
// Shape of the tree
// ---------------------------------------------------------------------------

unittest {
    // Everything peque throws is reachable from a single catch.
    static assert(is(ConnectionError     : PequeException));
    static assert(is(NotSupportedError   : PequeException));
    static assert(is(ConversionError     : PequeException));
    static assert(is(ResultError         : PequeException));
    static assert(is(QueryError          : PequeException));

    static assert(is(RowNotExistsError   : ResultError));
    static assert(is(ColNotExistsError   : ResultError));

    static assert(is(QueryClientError    : QueryError));
    static assert(is(QueryServerError    : QueryError));
    static assert(is(QueryEscapingError  : QueryClientError));
    static assert(is(IntegrityError      : QueryServerError));
    static assert(is(SerializationError  : QueryServerError));

    // Conversion is standalone: peque.converter depends on no connection,
    // query or result, so ConversionError must not hang under a result parent.
    static assert(!is(ConversionError : ResultError));
    static assert(!is(ConversionError : QueryError));
}


// ---------------------------------------------------------------------------
// SQLSTATE: type, kind and the fields PostgreSQL actually populates
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);

    // 23505 unique_violation — constraint, but NO column.
    auto uniq = collectException!IntegrityError(
        c.exec(`INSERT INTO exc_parent VALUES (2, 'a', 'y', 1)`));
    assert(uniq !is null, "duplicate key must raise IntegrityError");
    assert(uniq.sqlstate == "23505", uniq.sqlstate);
    assert(uniq.kind == IntegrityKind.unique);
    assert(uniq.constraintName == "exc_parent_tag_key", uniq.constraintName);
    assert(uniq.tableName == "exc_parent");
    // PostgreSQL reports no column for 23505; the offending columns appear only
    // in the localised DETAIL, which peque does not parse.
    assert(uniq.columnName == "");
    assert(uniq.messageDetail.length > 0);
    assert(!uniq.isRetriable());

    // 23503 foreign_key_violation — constraint, but NO column.
    auto fk = collectException!IntegrityError(
        c.exec(`INSERT INTO exc_child VALUES (1, 999)`));
    assert(fk !is null);
    assert(fk.sqlstate == "23503");
    assert(fk.kind == IntegrityKind.foreignKey);
    assert(fk.constraintName == "exc_child_parent_id_fkey", fk.constraintName);
    assert(fk.columnName == "");

    // 23502 not_null_violation — column, but NO constraint. The asymmetry.
    auto nn = collectException!IntegrityError(
        c.exec(`INSERT INTO exc_parent (id, tag) VALUES (3, 'b')`));
    assert(nn !is null);
    assert(nn.sqlstate == "23502");
    assert(nn.kind == IntegrityKind.notNull);
    assert(nn.columnName == "req", nn.columnName);
    assert(nn.constraintName == "",
        "PostgreSQL does not report a constraint for 23502");

    // 23514 check_violation.
    auto chk = collectException!IntegrityError(
        c.exec(`INSERT INTO exc_parent VALUES (4, 'c', 'z', -1)`));
    assert(chk !is null);
    assert(chk.sqlstate == "23514");
    assert(chk.kind == IntegrityKind.check);
    assert(chk.constraintName.length > 0);

    c.exec(`DROP TABLE IF EXISTS exc_child`);
    c.exec(`DROP TABLE IF EXISTS exc_parent`);
}

// An unknown code in a KNOWN class must still be typed — the dispatch is on the
// class, not the code, because PostgreSQL adds codes but not classes.
unittest {
    auto c = makeConn();

    // 22012 division_by_zero — class 22, which peque does not name: base type,
    // sqlstate intact.
    auto div = collectException!QueryServerError(c.exec(`SELECT 1/0`));
    assert(div !is null);
    assert(div.sqlstate == "22012", div.sqlstate);
    assert(div.sqlstateClass == "22");
    assert(cast(IntegrityError) div is null, "class 22 is not an integrity error");
    assert(!div.isRetriable());

    // 42P01 undefined_table — also unnamed, and still carries its state.
    auto undef = collectException!QueryServerError(c.exec(`SELECT * FROM no_such_table_xyz`));
    assert(undef !is null);
    assert(undef.sqlstate == "42P01", undef.sqlstate);
    assert(undef.messagePrimary.length > 0);
}


// ---------------------------------------------------------------------------
// Result access carries what was asked for and what was available
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    auto res = c.exec(`SELECT 1 AS a, 2 AS b`);

    auto col = collectException!ColNotExistsError(res.getRow(0)["nope"]);
    assert(col !is null);
    assert(col.colName == "nope");
    assert(col.nfields == 2);
    assert(col.available == ["a", "b"]);

    auto colIdx = collectException!ColNotExistsError(res.getRow(0)[7]);
    assert(colIdx !is null);
    assert(colIdx.colIndex == 7);
    assert(colIdx.nfields == 2);

    auto row = collectException!RowNotExistsError(res.getRow(5));
    assert(row !is null);
    assert(row.rowIndex == 5);
    assert(row.ntuples == 1);

    // Both are catchable as one category.
    assertThrown!ResultError(res.getRow(0)["nope"]);
    assertThrown!ResultError(res.getRow(5));
}


// ---------------------------------------------------------------------------
// Not every failure during a query is a QueryError
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();

    // A caller mistake peque catches before sending anything.
    assertThrown!QueryClientError(c.prepare("bad-name", "SELECT 1"));
    assertThrown!QueryError(c.prepare("bad-name", "SELECT 1"));   // still a query error

    // An unsupported feature is not a query error. Collect as the root and
    // inspect the dynamic type — collectException!QueryError would let a
    // non-QueryError escape.
    auto copyErr = collectException!PequeException(c.exec("COPY (SELECT 1) TO STDOUT"));
    assert(cast(NotSupportedError) copyErr !is null, "COPY must raise NotSupportedError");
    assert(cast(QueryError) copyErr is null,
        "COPY rejection sits outside QueryError: there is no correct call");
}


// ---------------------------------------------------------------------------
// 40001 serialization_failure — the retriable class
// ---------------------------------------------------------------------------

// Two serializable transactions with a read-write dependency: one must abort.
unittest {
    import peque.connection: IsolationLevel;

    auto setupConn = makeConn();
    setupConn.exec(`DROP TABLE IF EXISTS exc_ser`);
    setupConn.exec(`CREATE TABLE exc_ser (id int PRIMARY KEY, val int NOT NULL)`);
    setupConn.exec(`INSERT INTO exc_ser VALUES (1, 10), (2, 20)`);

    auto a = makeConn();
    auto b = makeConn();

    a.exec(`BEGIN ISOLATION LEVEL SERIALIZABLE`);
    b.exec(`BEGIN ISOLATION LEVEL SERIALIZABLE`);

    // Each reads what the other is about to write — a classic write skew.
    a.exec(`SELECT sum(val) FROM exc_ser`);
    b.exec(`SELECT sum(val) FROM exc_ser`);
    a.exec(`UPDATE exc_ser SET val = val + 1 WHERE id = 1`);
    b.exec(`UPDATE exc_ser SET val = val + 1 WHERE id = 2`);

    a.exec(`COMMIT`);

    // b's commit (or its next statement) must fail with 40001.
    SerializationError ser;
    try {
        b.exec(`COMMIT`);
    } catch (SerializationError e) {
        ser = e;
    }

    assert(ser !is null, "the second serializable transaction must abort");
    assert(ser.sqlstate == "40001", ser.sqlstate);
    assert(ser.sqlstateClass == "40");
    assert(ser.isRetriable(), "class 40 is the retry class");

    try b.exec(`ROLLBACK`); catch (Exception) {}
    setupConn.exec(`DROP TABLE IF EXISTS exc_ser`);
}


// ---------------------------------------------------------------------------
// ConversionError carries the direction and the offending value
// ---------------------------------------------------------------------------

// Declaring the fields is not enough — these assert they are populated.
unittest {
    import std.datetime: Date;
    import peque.converter.pg_to_d: convertTextTypeToD;
    import peque.converter.d_to_pg: convertToPG;
    import peque.converter.decimal: parseExactFloat;
    import peque.pg_type: PGType;

    // READ: source is the PostgreSQL type, target the D type.
    enum bad = "not-a-date";
    auto r = collectException!ConversionError(
        convertTextTypeToD!Date(bad.ptr, cast(int)bad.length, PGType.DATE));
    assert(r !is null);
    assert(r.sourceType == "DATE", r.sourceType);
    assert(r.targetType == "Date", r.targetType);
    assert(r.value == "not-a-date", r.value);
    assert(r.msg.canFind("Cannot parse date"), r.msg);

    // An unsupported pg_type → D type pairing reports both sides.
    enum n = "42";
    auto r2 = collectException!ConversionError(
        convertTextTypeToD!Date(n.ptr, cast(int)n.length, PGType.INT4));
    assert(r2 !is null);
    assert(r2.sourceType == "INT4" && r2.targetType == "Date");

    // WRITE: the direction reverses — source is the D type. The offending value
    // is NOT captured here: convertToPG runs on every string parameter, so
    // echoing it would leak secrets into logs. The NUL's index is reported
    // instead.
    auto w = collectException!ConversionError(convertToPG("secret\0value"));
    assert(w !is null);
    assert(w.targetType == "text", w.targetType);
    assert(w.sourceType.length > 0, "the D type being sent must be reported");
    assert(w.value == "", "a caller-supplied string must not be echoed back");
    assert(!w.msg.canFind("secret"), "the value must not leak into the message");
    assert(w.msg.canFind("index 6"), w.msg);

    // Standalone conversion: no connection, query or result involved.
    auto d = collectException!ConversionError(parseExactFloat!double("12x"));
    assert(d !is null);
    assert(d.sourceType == "text");
    assert(d.targetType == "double", d.targetType);
    assert(d.value == "12x", d.value);
}

// NULL access and binary format report what was being asked for.
unittest {
    auto c = makeConn();
    auto res = c.exec(`SELECT NULL::int AS n`);

    auto e = collectException!ConversionError(res.getValue!int(0, 0));
    assert(e !is null);
    assert(e.sourceType == "NULL");
    assert(e.targetType == "int", e.targetType);
}


// ---------------------------------------------------------------------------
// Phobos parse failures must not escape the hierarchy
// ---------------------------------------------------------------------------

// std.conv, std.datetime, std.json and std.uuid each raise their own exception
// type; all must be translated, or `catch (PequeException)` around a query
// would miss malformed text for most of the supported type table.
unittest {
    import std.datetime: Date, DateTime, SysTime;
    import std.json: JSONValue;
    import std.uuid: UUID;
    import peque.converter.pg_to_d: convertTextTypeToD;
    import peque.pg_type: PGType;

    static void mustBeOurs(T)(string data, PGType t, string label) {
        bool threwOurs = false;
        try
            convertTextTypeToD!T(data.ptr, cast(int)data.length, t);
        catch (ConversionError)
            threwOurs = true;
        catch (Exception e)
            assert(false, label ~ " leaked " ~ typeid(e).name ~
                   " — every failure must derive from PequeException");
        assert(threwOurs, label ~ " must reject malformed input");
    }

    mustBeOurs!int      ("abc",                 PGType.INT4,        "int");
    mustBeOurs!double   ("abc",                 PGType.FLOAT8,      "double");
    mustBeOurs!Date     ("not-a-date",          PGType.DATE,        "Date");
    mustBeOurs!DateTime ("xxxxxxxxxxxxxxxxxxx", PGType.TIMESTAMP,   "DateTime");
    mustBeOurs!SysTime  ("xxxxxxxxxxxxxxxxxxx", PGType.TIMESTAMPTZ, "SysTime");
    mustBeOurs!JSONValue("{",                   PGType.JSONB,       "JSONValue");
    mustBeOurs!UUID     ("zz",                  PGType.UUID,        "UUID");
}


// An empty or comment-only statement carries no SQLSTATE, so it is a caller
// error rather than a server rejection — routing it to QueryServerError would
// leave `sqlstate` empty and break that type's contract.
unittest {
    auto c = makeConn();
    foreach (q; ["", "   ", "-- just a comment"]) {
        auto e = collectException!QueryClientError(c.exec(q));
        assert(e !is null, "empty query must raise QueryClientError: '" ~ q ~ "'");
    }

    // Every QueryServerError that does escape carries a SQLSTATE.
    auto srv = collectException!QueryServerError(c.exec(`SELECT * FROM no_such_table_xyz`));
    assert(srv !is null && srv.sqlstate.length == 5, srv.sqlstate);
}
