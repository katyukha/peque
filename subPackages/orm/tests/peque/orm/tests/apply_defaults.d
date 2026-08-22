/** Tests for applyDefaults() convention in CRUDMixin.
  *
  * Covers:
  *  - applyDefaults() is called before insert when present on model
  *  - applyDefaults() is NOT called by update(ref M)
  *  - D struct field defaults (compile-time constants) work without applyDefaults
  *  - Models without applyDefaults compile and behave normally
  **/
module peque.orm.tests.apply_defaults;

private import std.datetime: Clock, SysTime;
private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

// Model with applyDefaults — runtime-computed defaults
@model("peque_orm_events")
struct Event {
    @primaryKey int     id;
    @field      string  name;
    @field      string  status;
    @field      SysTime createdAt;

    void applyDefaults() {
        if (status.length == 0) status = "pending";
        if (createdAt == SysTime.init) createdAt = Clock.currTime();
    }
}

// Model with D struct field defaults only — no applyDefaults needed
@model("peque_orm_settings")
struct Setting {
    @primaryKey int    id;
    @field      string key;
    @field      bool   enabled = true;
    @field      int    priority = 10;
}


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}


// ---------------------------------------------------------------------------
// applyDefaults called before insert
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS peque_orm_events");
    c.exec("CREATE TABLE peque_orm_events (
        id        SERIAL PRIMARY KEY,
        name      TEXT NOT NULL,
        status    TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL
    )");

    auto repo = Repository!(Event, Connection)(&c);

    // status and createdAt are at D init — applyDefaults fills them
    auto e = Event(0, "Launch", "", SysTime.init);
    auto inserted = repo.insert(e);

    assert(inserted.id >= 1);
    assert(inserted.name == "Launch");
    assert(inserted.status == "pending");
    assert(inserted.createdAt != SysTime.init);

    // caller-supplied status is preserved (applyDefaults checks length)
    auto e2 = Event(0, "Deploy", "running", SysTime.init);
    auto ins2 = repo.insert(e2);
    assert(ins2.status == "running");
}


// ---------------------------------------------------------------------------
// applyDefaults NOT called by update
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    auto repo = Repository!(Event, Connection)(&c);

    auto e = Event(0, "Init", "", SysTime.init);
    auto inserted = repo.insert(e);
    assert(inserted.status == "pending");

    // Manually set status to "" and update — applyDefaults must NOT fire
    inserted.status = "";
    repo.update(inserted);

    auto fetched = repo.findById(inserted.id).get;
    assert(fetched.status == "", "update must not invoke applyDefaults");
}


// ---------------------------------------------------------------------------
// applyDefaults called by insertMany
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    // reuse table from previous tests (already created above)
    auto repo = Repository!(Event, Connection)(&c);

    auto batch = [
        Event(0, "BatchA", "", SysTime.init),
        Event(0, "BatchB", "running", SysTime.init),
        Event(0, "BatchC", "", SysTime.init),
    ];
    auto inserted = repo.insertMany(batch);

    assert(inserted.length == 3);
    // applyDefaults must have been called on each record
    assert(inserted[0].status == "pending");   // was ""   → filled
    assert(inserted[1].status == "running");   // was set  → preserved
    assert(inserted[2].status == "pending");   // was ""   → filled
    foreach (r; inserted)
        assert(r.createdAt != SysTime.init, "createdAt must be set by applyDefaults");
}


// ---------------------------------------------------------------------------
// D struct field defaults — no applyDefaults needed
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS peque_orm_settings");
    c.exec("CREATE TABLE peque_orm_settings (
        id       SERIAL PRIMARY KEY,
        key      TEXT NOT NULL,
        enabled  BOOLEAN NOT NULL,
        priority INTEGER NOT NULL
    )");

    auto repo = Repository!(Setting, Connection)(&c);

    // Partially initialised — enabled and priority carry their D defaults
    auto s = Setting(0, "theme");
    auto inserted = repo.insert(s);

    assert(inserted.enabled  == true);
    assert(inserted.priority == 10);

    // Explicit override still works
    auto s2 = Setting(0, "mode", false, 99);
    auto ins2 = repo.insert(s2);
    assert(ins2.enabled  == false);
    assert(ins2.priority == 99);
}
