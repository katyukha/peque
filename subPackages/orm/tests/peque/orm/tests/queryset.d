/** Integration tests for peque:orm QuerySet.
  *
  * Covers:
  *  - query() returns an empty QuerySet
  *  - all() with no filters returns all rows
  *  - where() with one filter
  *  - where() chained (two filters, param renumbering)
  *  - orderBy() override
  *  - limit() / offset()
  *  - first() — found and not found
  *  - count()
  *  - exists()
  *  - delete_() — with and without filter
  *  - Branching from a base QuerySet
  **/
module peque.orm.tests.queryset;

private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.orm;


@model("qs_items")
struct Item {
    @primaryKey int    id;
    @field      string name;
    @field      bool   active;
    @field      int    score;
}

alias QsReg = Registry!(Bind!(Item, ModelRepo!Item));

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

// Shared setup: recreate table and seed rows.
private Item[] seed(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS qs_items;");
    c.exec(schemaSQL!QsReg());

    auto repo = Repository!(Item, Connection)(&c);

    Item[] inserted;
    foreach (row; [
        Item(0, "Alpha", true,  10),
        Item(0, "Beta",  false, 20),
        Item(0, "Gamma", true,  30),
        Item(0, "Delta", false, 40),
    ]) {
        inserted ~= repo.insert(row);
    }
    return inserted;
}


// ---------------------------------------------------------------------------
// all() — no filter
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto all = repo.query().all();
    assert(all.length == 4);
}


// ---------------------------------------------------------------------------
// where() — single filter
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto active = repo.query().whereRaw("active = $1", true).all();
    assert(active.length == 2);
    foreach (r; active) assert(r.active == true);
}


// ---------------------------------------------------------------------------
// where() chained — param renumbering
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    // Both conditions use local $1; the second must be renumbered to $2.
    auto result = repo.query()
                      .whereRaw("active = $1", true)
                      .whereRaw("score > $1", 15)
                      .all();
    assert(result.length == 1);
    assert(result[0].name == "Gamma");
}


// ---------------------------------------------------------------------------
// orderBy()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto desc = repo.query().orderBy("score DESC").all();
    assert(desc[0].score == 40);
    assert(desc[$-1].score == 10);
}


// ---------------------------------------------------------------------------
// limit() / offset()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto page = repo.query().orderBy("score ASC").limit(2).offset(1).all();
    assert(page.length == 2);
    assert(page[0].score == 20);
    assert(page[1].score == 30);
}


// ---------------------------------------------------------------------------
// first()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto found = repo.query().whereRaw("name = $1", "Beta").first();
    assert(!found.isNull);
    assert(found.get.name == "Beta");

    auto notFound = repo.query().whereRaw("name = $1", "NoSuch").first();
    assert(notFound.isNull);
}


// ---------------------------------------------------------------------------
// count()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    assert(repo.query().count() == 4);
    assert(repo.query().whereRaw("active = $1", true).count() == 2);
    assert(repo.query().whereRaw("score > $1", 100).count() == 0);
}


// ---------------------------------------------------------------------------
// exists()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    assert( repo.query().exists());
    assert( repo.query().whereRaw("name = $1", "Alpha").exists());
    assert(!repo.query().whereRaw("name = $1", "Ghost").exists());
}


// ---------------------------------------------------------------------------
// delete_()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto deleted = repo.query().whereRaw("active = $1", false).delete_();
    assert(deleted == 2);
    assert(repo.query().count() == 2);
}

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto deleted = repo.query().delete_();
    assert(deleted == 4);
    assert(repo.query().count() == 0);
}


// ---------------------------------------------------------------------------
// Branching from a base QuerySet
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    auto base    = repo.query().whereRaw("active = $1", true);
    auto high    = base.whereRaw("score > $1", 25).all();
    auto low     = base.whereRaw("score < $1", 25).all();

    // base is unchanged
    assert(base.all().length == 2);
    assert(high.length == 1);
    assert(high[0].name == "Gamma");
    assert(low.length == 1);
    assert(low[0].name == "Alpha");
}
