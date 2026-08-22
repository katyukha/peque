/** Integration tests for CRUDMixin.upsert.
  *
  * Covers:
  *  - upsert(ref M) with PK=0 → plain INSERT (delegates to insert())
  *  - upsert(ref M) with PK set → INSERT ON CONFLICT (pk) DO UPDATE
  *  - Idempotence: upsert of same data returns same record, count stays 1
  *  - upsert!"field"(ref M) with new natural key → INSERT
  *  - upsert!"field"(ref M) with existing natural key → DO UPDATE
  *  - upsert!"field" with PK set → includes PK in INSERT, PK not overwritten on conflict
  *  - Composite conflict key: upsert!("f1","f2")
  *  - RETURNING: returned record reflects DB state
  **/
module peque.orm.tests.upsert;

private import std.process: environment;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, unique, uniqueTogether;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("ups_items")
struct UpsItem {
    @primaryKey         int    id;
    @field @unique      string code;
    @field              string name;
    @field              int    score;
}

@model("ups_settings")
@uniqueTogether!("userId", "key")
struct UpsSetting {
    @primaryKey int    id;
    @field      int    userId;
    @field      string key;
    @field      string value;
}

alias UpsReg = Registry!(
    Bind!(UpsItem,    ModelRepo!UpsItem),
    Bind!(UpsSetting, ModelRepo!UpsSetting),
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

private void createTables(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS ups_settings;");
    c.exec("DROP TABLE IF EXISTS ups_items;");
    c.exec(schemaSQL!UpsReg());
}


// ---------------------------------------------------------------------------
// upsert(ref M) — PK=0 → plain INSERT
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    auto rec = UpsItem(0, "A", "Alpha", 10);
    auto ins  = repo.upsert(rec);

    assert(ins.id > 0,         "PK must be assigned by DB");
    assert(ins.code  == "A");
    assert(ins.name  == "Alpha");
    assert(ins.score == 10);
    assert(repo.query().count() == 1);
}


// ---------------------------------------------------------------------------
// upsert(ref M) — PK set → ON CONFLICT (pk) DO UPDATE
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    // First insert via upsert (PK=0 → INSERT)
    auto rec = UpsItem(0, "B", "Beta", 20);
    auto ins = repo.upsert(rec);
    assert(ins.id > 0);

    // Modify and upsert again with PK set → ON CONFLICT DO UPDATE
    ins.name  = "Beta-Updated";
    ins.score = 99;
    auto updated = repo.upsert(ins);

    assert(updated.id    == ins.id,       "PK must not change");
    assert(updated.name  == "Beta-Updated");
    assert(updated.score == 99);
    assert(repo.query().count() == 1,     "must still be 1 row");
}


// ---------------------------------------------------------------------------
// upsert(ref M) — idempotent: same data twice, count stays 1
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    auto rec  = UpsItem(0, "C", "Gamma", 30);
    auto ins  = repo.upsert(rec);
    auto ins2 = repo.upsert(ins);   // same data, PK set

    assert(ins2.id    == ins.id);
    assert(ins2.name  == ins.name);
    assert(ins2.score == ins.score);
    assert(repo.query().count() == 1);
}


// ---------------------------------------------------------------------------
// upsert!"code" — new natural key → INSERT
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    auto rec = UpsItem(0, "X", "Xenon", 42);
    auto ins = repo.upsert!"code"(rec);

    assert(ins.id > 0);
    assert(ins.code  == "X");
    assert(ins.name  == "Xenon");
    assert(ins.score == 42);
    assert(repo.query().count() == 1);
}


// ---------------------------------------------------------------------------
// upsert!"code" — existing natural key → DO UPDATE, PK unchanged
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    auto first  = UpsItem(0, "Y", "Original", 1);
    auto ins    = repo.upsert!"code"(first);
    auto origId = ins.id;

    // Same code, different name and score
    auto second  = UpsItem(0, "Y", "Replaced", 999);
    auto updated = repo.upsert!"code"(second);

    assert(updated.id    == origId,    "PK must not change on conflict");
    assert(updated.code  == "Y");
    assert(updated.name  == "Replaced");
    assert(updated.score == 999);
    assert(repo.query().count() == 1,  "must still be 1 row");
}


// ---------------------------------------------------------------------------
// upsert!"code" with PK set — PK included in INSERT, not overwritten on conflict
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsItem, Connection)(&c);

    // First insert to get a real PK
    auto rec = UpsItem(0, "Z", "Zeta", 7);
    auto ins = repo.upsert!"code"(rec);

    // Upsert again with PK set — code conflicts, PK on existing row is preserved
    auto attempt = UpsItem(ins.id + 1000, "Z", "Zeta-New", 8);
    auto result  = repo.upsert!"code"(attempt);

    assert(result.id   == ins.id,  "PK must not be overwritten on conflict");
    assert(result.name == "Zeta-New");
    assert(result.score == 8);
    assert(repo.query().count() == 1);

    // Verify in DB: original PK has the updated fields, attempt PK does not exist
    auto inDb = repo.findById(ins.id).get;
    assert(inDb.name  == "Zeta-New");
    assert(inDb.score == 8);
    assert(repo.findById(ins.id + 1000).isNull,
        "spurious row with attempt PK must not exist in DB");
}


// ---------------------------------------------------------------------------
// Composite conflict key: upsert!("userId", "key")
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTables(c);
    auto repo = Repository!(UpsSetting, Connection)(&c);

    auto s1 = UpsSetting(0, 1, "theme", "dark");
    auto ins = repo.upsert!("userId", "key")(s1);
    assert(ins.id > 0);
    assert(ins.value == "dark");

    // Same (userId, key) → update value
    auto s2      = UpsSetting(0, 1, "theme", "light");
    auto updated = repo.upsert!("userId", "key")(s2);
    assert(updated.id    == ins.id,  "PK must not change");
    assert(updated.value == "light");
    assert(repo.query().count() == 1);

    // Different userId → new row
    auto s3  = UpsSetting(0, 2, "theme", "dark");
    auto ins2 = repo.upsert!("userId", "key")(s3);
    assert(ins2.id != ins.id);
    assert(repo.query().count() == 2);
}
