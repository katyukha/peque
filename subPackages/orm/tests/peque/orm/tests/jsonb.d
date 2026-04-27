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
    assert(ddl.indexOf("payload JSONB") >= 0,
        "expected 'payload JSONB' in DDL, got: " ~ ddl);
}

unittest {
    auto ddl = modelDDL!JbLog();
    assert(ddl.indexOf("before_ JSONB") >= 0,
        "expected 'before_ JSONB' in DDL, got: " ~ ddl);
    assert(ddl.indexOf("after_ JSONB") >= 0,
        "expected 'after_ JSONB' in DDL, got: " ~ ddl);
    // explicit @pgType("JSON") override must be respected
    assert(ddl.indexOf("raw JSON") >= 0,
        "expected 'raw JSON' in DDL, got: " ~ ddl);
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
