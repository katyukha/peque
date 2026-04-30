/** Integration tests for QuerySet.set!().update() — partial / bulk UPDATE.
  *
  * Covers:
  *  - Single-row update via PK WHERE + set!()
  *  - Bulk update: multiple rows affected
  *  - Multiple set!() calls in one chain
  *  - update() when no rows match → returns 0
  **/
module peque.orm.tests.queryset_update;

private import std.process: environment;
private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.orm;


// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

@model("qu_items")
struct QuItem {
    @primaryKey int    id;
    @field      string name;
    @field      bool   active;
    @field      int    score;
}

alias QuReg = Registry!(Bind!(QuItem, ModelRepo!QuItem));


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

private QuItem[] seed(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS qu_items;");
    c.exec(schemaSQL!QuReg());

    auto repo = Repository!(QuItem, Connection)(&c);
    QuItem[] rows;
    foreach (r; [
        QuItem(0, "Alpha", true,  10),
        QuItem(0, "Beta",  false, 20),
        QuItem(0, "Gamma", true,  30),
        QuItem(0, "Delta", false, 40),
    ]) rows ~= repo.insert(r);
    return rows;
}


// ---------------------------------------------------------------------------
// Single-row update via PK
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    auto id = rows[0].id;
    auto affected = repo.query()
                        .whereRaw("id = $1", id)
                        .set!("name")("Updated Name")
                        .update();

    assert(affected == 1);
    auto reloaded = repo.findById(id).get;
    assert(reloaded.name == "Updated Name");
    assert(reloaded.active == true);   // unchanged
    assert(reloaded.score  == 10);     // unchanged
}


// ---------------------------------------------------------------------------
// Bulk update — multiple rows
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    // Activate all inactive rows
    auto affected = repo.query()
                        .whereRaw("active = $1", false)
                        .set!("active")(true)
                        .update();

    assert(affected == 2);  // Beta and Delta

    auto all = repo.query().all();
    foreach (r; all)
        assert(r.active == true);
}


// ---------------------------------------------------------------------------
// Multiple set!() calls
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    // Deactivate and zero out score for all inactive rows
    auto affected = repo.query()
                        .whereRaw("active = $1", false)
                        .set!("active")(true)
                        .set!("score")(0)
                        .update();

    assert(affected == 2);

    auto changed = repo.query().whereRaw("score = $1", 0).all();
    assert(changed.length == 2);
    foreach (r; changed) {
        assert(r.active == true);
        assert(r.score  == 0);
    }
}


// ---------------------------------------------------------------------------
// No rows matched → returns 0
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    auto affected = repo.query()
                        .whereRaw("id = $1", -999)
                        .set!("name")("Ghost")
                        .update();

    assert(affected == 0);
}


// ---------------------------------------------------------------------------
// update() with no set!() calls — must throw before hitting the database
// ---------------------------------------------------------------------------

unittest {
    import std.exception: assertThrown;
    import core.exception: AssertError;

    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    // Calling update() without any set!() is a programming error —
    // it would generate "UPDATE ... SET  WHERE ..." which is invalid SQL.
    assertThrown!AssertError(
        repo.query().whereRaw("id = $1", rows[0].id).update(),
        "update() with no set!() calls must throw before executing SQL");
}
