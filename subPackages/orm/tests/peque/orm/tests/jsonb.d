/** Integration tests for JSONB column support in peque:orm.
  *
  * Covers:
  *  - schemaSQL emits JSONB (not JSON) for JSONValue fields without @pgType
  *  - @pgType("JSON") override still emits JSON
  *  - insert / findById round-trip with JSONValue field
  *  - Nullable!JSONValue — null and non-null
  *  - where!"field"(val) equality on a JSONB column
  **/
module peque.orm.tests.jsonb;

private import std.json: JSONValue, JSONType, parseJSON;
private import std.process: environment;
private import std.string: indexOf;
private import std.typecons: Nullable, nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, pgType;
private import peque.orm;
private import peque.orm.field: F;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("jb_events")
struct JbEvent {
    @primaryKey int       id;
    @field      string    name;
    @field      JSONValue payload;
}

@model("jb_logs")
struct JbLog {
    @primaryKey int              id;
    @field      string           action;
    @field      Nullable!JSONValue before_;
    @field      Nullable!JSONValue after_;
    @field      @pgType("JSON") JSONValue raw;   // explicit JSON downgrade
}

alias JbReg = Registry!(
    Bind!(JbEvent, ModelRepo!JbEvent),
    Bind!(JbLog,   ModelRepo!JbLog),
);

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
    c.exec("DROP TABLE IF EXISTS jb_logs;");
    c.exec("DROP TABLE IF EXISTS jb_events;");
    c.exec(schemaSQL!JbReg());
}


// ---------------------------------------------------------------------------
// DDL — auto-detect JSONValue → JSONB
// ---------------------------------------------------------------------------

unittest {
    auto ddl = modelDDL!JbEvent();
    assert(ddl.indexOf(`"payload" JSONB`) >= 0,
        "expected quoted 'payload' JSONB in DDL, got: " ~ ddl);
}

unittest {
    auto ddl = modelDDL!JbLog();
    assert(ddl.indexOf(`"before_" JSONB`) >= 0,
        "expected quoted 'before_' JSONB in DDL, got: " ~ ddl);
    assert(ddl.indexOf(`"after_" JSONB`) >= 0,
        "expected quoted 'after_' JSONB in DDL, got: " ~ ddl);
    // explicit @pgType("JSON") override must be respected
    assert(ddl.indexOf(`"raw" JSON`) >= 0,
        "expected quoted 'raw' JSON in DDL, got: " ~ ddl);
}


// ---------------------------------------------------------------------------
// Round-trip — insert / findById
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    auto payload = parseJSON(`{"event": "login", "uid": 42}`);
    auto row = JbEvent(0, "user_login", payload);
    auto inserted = repo.insert(row);
    assert(inserted.id > 0);

    auto found = repo.findById(inserted.id).get;
    assert(found.name == "user_login");
    assert(found.payload["event"].str == "login");
    assert(found.payload["uid"].integer == 42);
}

unittest {
    auto c    = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    // nested object round-trip
    auto payload = parseJSON(`{"meta": {"tags": ["a", "b"], "score": 3.14}}`);
    auto row = JbEvent(0, "complex", payload);
    auto inserted = repo.insert(row);

    auto found = repo.findById(inserted.id).get;
    assert(found.payload["meta"]["tags"][0].str == "a");
    assert(found.payload["meta"]["score"].floating == 3.14);
}


// ---------------------------------------------------------------------------
// Nullable!JSONValue — null and non-null
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setup(c);
    auto repo = Repository!(JbLog, Connection)(&c);

    auto before  = parseJSON(`{"status": "draft"}`);
    auto after   = parseJSON(`{"status": "open"}`);
    auto emptyJs = parseJSON(`{}`);

    // non-null before + after
    auto r1 = JbLog(0, "status_change", before.nullable, after.nullable, emptyJs);
    auto row1 = repo.insert(r1);
    assert(!row1.before_.isNull);
    assert(row1.before_.get["status"].str == "draft");

    // null before (new record creation)
    auto r2 = JbLog(0, "create", Nullable!JSONValue.init, after.nullable, emptyJs);
    auto row2 = repo.insert(r2);
    assert(row2.before_.isNull);
    assert(!row2.after_.isNull);
    assert(row2.after_.get["status"].str == "open");
}


// ---------------------------------------------------------------------------
// QuerySet with JSONValue field
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    auto p1 = parseJSON(`{"type": "click"}`);
    auto p2 = parseJSON(`{"type": "view"}`);
    auto e1 = JbEvent(0, "e1", p1);
    auto e2 = JbEvent(0, "e2", p2);
    repo.insert(e1);
    repo.insert(e2);

    // count all
    assert(repo.query().count() == 2);

    // filter by name, check payload survives
    auto r = repo.query().where!"name"("e1").all();
    assert(r.length == 1);
    assert(r[0].payload["type"].str == "click");
}


// ---------------------------------------------------------------------------
// F!(M, "field").get("key") — JSONB text-extraction predicate
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    auto ea = JbEvent(0, "a", parseJSON(`{"type": "click", "score": "42"}`));
    auto eb = JbEvent(0, "b", parseJSON(`{"type": "view",  "score": "10"}`));
    auto ec = JbEvent(0, "c", parseJSON(`{"type": "click", "score": "99"}`));
    repo.insert(ea); repo.insert(eb); repo.insert(ec);

    // equality
    auto clicks = repo.query()
        .where(F!(JbEvent, "payload").get("type")("click"))
        .all();
    assert(clicks.length == 2);

    // ne
    auto notClicks = repo.query()
        .where(F!(JbEvent, "payload").get("type").ne("click"))
        .all();
    assert(notClicks.length == 1);
    assert(notClicks[0].name == "b");

    // contains (IN)
    auto multi = repo.query()
        .where(F!(JbEvent, "payload").get("type").contains(["click", "view"]))
        .all();
    assert(multi.length == 3);

    // gte on extracted text (lexicographic — good enough for numeric strings here)
    auto highScore = repo.query()
        .where(F!(JbEvent, "payload").get("score").gte("90"))
        .all();
    assert(highScore.length == 1);
    assert(highScore[0].name == "c");

    // runtime key variable works (key is not a compile-time constant)
    string lang = "type";
    auto byVar = repo.query()
        .where(F!(JbEvent, "payload").get(lang)("view"))
        .all();
    assert(byVar.length == 1);
    assert(byVar[0].name == "b");

    // type-free F!"field".get("key") also works
    auto byFree = repo.query()
        .where(F!"payload".get("type")("click"))
        .all();
    assert(byFree.length == 2);
}


// ---------------------------------------------------------------------------
// get("key") on missing key — PostgreSQL returns NULL
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    auto ea = JbEvent(0, "a", parseJSON(`{"type": "click"}`));
    auto eb = JbEvent(0, "b", parseJSON(`{"type": "view", "extra": "yes"}`));
    repo.insert(ea); repo.insert(eb);

    // Missing key → NULL in DB → equality with any value yields no rows
    auto r = repo.query()
        .where(F!(JbEvent, "payload").get("extra")("yes"))
        .all();
    assert(r.length == 1);
    assert(r[0].name == "b");

    // isNull on missing key matches all rows where the key is absent
    auto missing = repo.query()
        .where(F!(JbEvent, "payload").get("extra").isNull)
        .all();
    assert(missing.length == 1);
    assert(missing[0].name == "a");
}


// ---------------------------------------------------------------------------
// get("key") on non-object JSON — PostgreSQL returns NULL
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(JbEvent, Connection)(&c);

    // array and scalar JSON values produce NULL for ->>'key'
    auto ea = JbEvent(0, "arr",    parseJSON(`[1, 2, 3]`));
    auto eb = JbEvent(0, "scalar", parseJSON(`"hello"`));
    auto ec = JbEvent(0, "obj",    parseJSON(`{"k": "v"}`));
    repo.insert(ea); repo.insert(eb); repo.insert(ec);

    // ->>'k' on array or scalar is NULL → matched by isNull
    auto nulls = repo.query()
        .where(F!(JbEvent, "payload").get("k").isNull)
        .all();
    assert(nulls.length == 2);

    // only the object row has a non-null value for key "k"
    auto found = repo.query()
        .where(F!(JbEvent, "payload").get("k")("v"))
        .all();
    assert(found.length == 1);
    assert(found[0].name == "obj");
}


// ---------------------------------------------------------------------------
// get("key") injection guard — unsafe keys are rejected with
// QueryEscapingError (a runtime enforce, so it also holds in -release builds)
// ---------------------------------------------------------------------------

unittest {
    import std.exception: assertThrown;
    import peque.exception: QueryEscapingError;

    F!(JbEvent, "payload").get("k' OR '1'='1").assertThrown!QueryEscapingError;
    F!(JbEvent, "payload").get("k\\").assertThrown!QueryEscapingError;
    F!(JbEvent, "payload").get("k\0y").assertThrown!QueryEscapingError;

    // benign keys still work
    auto p = F!(JbEvent, "payload").get("with space-and.dots")("v");
}
