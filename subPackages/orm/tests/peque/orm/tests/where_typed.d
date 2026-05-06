/** Integration tests for type-safe WHERE predicates (F expressions).
  *
  * Covers:
  *  - where!"field"(val) — compile-time equality
  *  - whereIn!"field"(vals) — compile-time IN
  *  - whereIn!"field"([]) — empty slice throws PequeException
  *  - F!(M,"field") comparison operators: >=, <=, >, <, !=
  *  - F!(M,"field").like()
  *  - F!(M,"field").isNull
  *  - OR composition via |
  *  - AND composition via &
  *  - NOT via ~
  *  - Mixed typed + whereRaw predicates
  *  - Chained where() calls (implicit AND)
  **/
module peque.orm.tests.where_typed;

private import std.process: environment;
private import std.typecons: Nullable;
private import std.exception: assertThrown;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.exception: PequeException;
private import peque.orm;


@model("wt_items")
struct WtItem {
    @primaryKey int    id;
    @field      string name;
    @field      bool   active;
    @field      int    score;
    @field      string status;
}

alias WtReg = Registry!(Bind!(WtItem, ModelRepo!WtItem));

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

private WtItem[] seed(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS wt_items;");
    c.exec(schemaSQL!WtReg());
    auto repo = Repository!(WtItem, Connection)(&c);
    WtItem[] rows;
    foreach (r; [
        WtItem(0, "Alpha",   true,  10, "active"),
        WtItem(0, "Beta",    false, 20, "pending"),
        WtItem(0, "Gamma",   true,  30, "active"),
        WtItem(0, "Delta",   false, 40, "inactive"),
        WtItem(0, "Epsilon", true,  50, "pending"),
    ]) rows ~= repo.insert(r);
    return rows;
}


// ---------------------------------------------------------------------------
// where!"field"(val) — equality sugar
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto active = repo.query().where!"active"(true).all();
    assert(active.length == 3);
    foreach (r; active) assert(r.active == true);
}

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().where!"name"("Gamma").all();
    assert(r.length == 1);
    assert(r[0].score == 30);
}


// ---------------------------------------------------------------------------
// whereIn!"field"(vals) — IN sugar
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().whereIn!"status"(["active", "pending"]).all();
    assert(r.length == 4);   // Alpha, Beta, Gamma, Epsilon
}

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().whereIn!"score"([10, 30, 50]).all();
    assert(r.length == 3);
    foreach (ri; r) assert(ri.active == true);
}


// ---------------------------------------------------------------------------
// F!(M,"field") comparison operators
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // >= 30
    auto r = repo.query().where(F!(WtItem, "score").gte(30)).all();
    assert(r.length == 3);

    // < 30
    auto r2 = repo.query().where(F!(WtItem, "score").lt(30)).all();
    assert(r2.length == 2);

    // != "active"
    auto r3 = repo.query().where(F!(WtItem, "status").ne("active")).all();
    assert(r3.length == 3);
}


// ---------------------------------------------------------------------------
// F!(M,"field").like()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().where(F!(WtItem, "name").like("G%")).all();
    assert(r.length == 1);
    assert(r[0].name == "Gamma");

    auto r2 = repo.query().where(F!(WtItem, "name").like("%a%")).all();
    assert(r2.length == 4);  // Alpha, Beta, Gamma, Delta (all contain 'a')
}


// ---------------------------------------------------------------------------
// F!(M,"field").isNull — no NULLable fields in WtItem, so test NOT isNull
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // status is never NULL — NOT isNull should return all rows
    auto r = repo.query().where(~F!(WtItem, "status").isNull).all();
    assert(r.length == 5);
}


// ---------------------------------------------------------------------------
// OR composition
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto pred = F!(WtItem, "status")("active") | F!(WtItem, "status")("inactive");
    auto r = repo.query().where(pred).all();
    assert(r.length == 3);  // Alpha, Gamma, Delta
}

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // score < 15 OR score > 45
    auto pred = F!(WtItem, "score").lt(15) | F!(WtItem, "score").gt(45);
    auto r = repo.query().where(pred).all();
    assert(r.length == 2);  // Alpha(10) + Epsilon(50)
}


// ---------------------------------------------------------------------------
// AND composition via &
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto pred = F!(WtItem, "active")(true) & F!(WtItem, "score").gte(30);
    auto r = repo.query().where(pred).all();
    assert(r.length == 2);  // Gamma(30) + Epsilon(50)
}


// ---------------------------------------------------------------------------
// NOT via ~
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().where(~F!(WtItem, "active")(true)).all();
    assert(r.length == 2);
    foreach (ri; r) assert(ri.active == false);
}


// ---------------------------------------------------------------------------
// Chained where() — implicit AND
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query()
                 .where!"active"(true)
                 .where(F!(WtItem, "score").gte(30))
                 .all();
    assert(r.length == 2);  // Gamma + Epsilon
}


// ---------------------------------------------------------------------------
// Mixed typed predicate + whereRaw
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // Typed filter for active, raw filter for score
    auto r = repo.query()
                 .where!"active"(true)
                 .whereRaw("score > $1", 20)
                 .all();
    assert(r.length == 2);  // Gamma(30) + Epsilon(50)
}


// ---------------------------------------------------------------------------
// Complex OR with three branches
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto pred = F!(WtItem, "name")("Alpha")
              | F!(WtItem, "name")("Gamma")
              | F!(WtItem, "name")("Epsilon");
    auto r = repo.query().where(pred).orderBy("score ASC").all();
    assert(r.length == 3);
    assert(r[0].name == "Alpha");
    assert(r[1].name == "Gamma");
    assert(r[2].name == "Epsilon");
}


// ---------------------------------------------------------------------------
// whereIn! / contains() with empty slice — returns zero rows (SQL: FALSE)
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // Empty slice → Predicate.none → WHERE FALSE → zero rows, no SQL error.
    assert(repo.query().whereIn!"name"(cast(string[])[]).all().length == 0);
    assert(repo.query().where(F!(WtItem, "score").contains(cast(int[])[])).all().length == 0);
}
