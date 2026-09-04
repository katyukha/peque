/** Integration tests for CRUDMixin.insertMany.
  *
  * Covers:
  *  - insertMany([]) — empty fast-path returns []
  *  - insertMany with one record — identical to insert()
  *  - insertMany with multiple records — single round-trip, all PKs assigned
  *  - returned rows match insertion order and field values
  *  - inserted rows are queryable via findAll / query()
  **/
module peque.orm.tests.insert_many;

private import std.process: environment;
private import std.algorithm: sort, map;
private import std.array: array;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.orm;


@model("im_items")
struct ImItem {
    @primaryKey int    id;
    @field      string name;
    @field      int    score;
    @field      bool   active;
}

alias ImReg = Registry!(Bind!(ImItem, ModelRepo!ImItem));

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

private void createTable(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS im_items;");
    c.exec(schemaSQL!ImReg());
}


// ---------------------------------------------------------------------------
// Empty slice — must return [] without touching the DB
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTable(c);
    auto repo = Repository!(ImItem, Connection)(&c);

    ImItem[] empty;
    auto result = repo.insertMany(empty);
    assert(result.length == 0);
    assert(repo.query().count() == 0);
}


// ---------------------------------------------------------------------------
// Single record — same semantics as insert()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTable(c);
    auto repo = Repository!(ImItem, Connection)(&c);

    auto rows = repo.insertMany([ImItem(0, "Alpha", 10, true)]);
    assert(rows.length == 1);
    assert(rows[0].id > 0,     "PK must be assigned by the DB");
    assert(rows[0].name   == "Alpha");
    assert(rows[0].score  == 10);
    assert(rows[0].active == true);

    assert(repo.query().count() == 1);
}


// ---------------------------------------------------------------------------
// Multiple records — all PKs assigned, order preserved
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTable(c);
    auto repo = Repository!(ImItem, Connection)(&c);

    auto input = [
        ImItem(0, "Alpha",   10, true),
        ImItem(0, "Beta",    20, false),
        ImItem(0, "Gamma",   30, true),
        ImItem(0, "Delta",   40, false),
        ImItem(0, "Epsilon", 50, true),
    ];
    auto rows = repo.insertMany(input);

    assert(rows.length == 5);
    foreach (i, ref r; rows) {
        assert(r.id > 0,          "every row must get a generated PK");
        assert(r.name  == input[i].name);
        assert(r.score == input[i].score);
        assert(r.active == input[i].active);
    }
    // All PKs must be distinct
    import std.algorithm: sort;
    int[] ids = rows.map!(r => r.id).array;
    ids.sort();
    foreach (i; 1 .. ids.length)
        assert(ids[i] != ids[i-1], "PKs must be unique");
}


// ---------------------------------------------------------------------------
// Rows are actually in the DB after insertMany
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTable(c);
    auto repo = Repository!(ImItem, Connection)(&c);

    repo.insertMany([
        ImItem(0, "X", 1, true),
        ImItem(0, "Y", 2, false),
        ImItem(0, "Z", 3, true),
    ]);

    assert(repo.query().count() == 3);
    auto actives = repo.query().where!"active"(true).all();
    assert(actives.length == 2);
}


// ---------------------------------------------------------------------------
// insertMany after existing rows — no conflict, PKs continue correctly
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    createTable(c);
    auto repo = Repository!(ImItem, Connection)(&c);

    auto seed  = ImItem(0, "Seed", 0, false);
    auto first = repo.insert(seed);
    auto more  = repo.insertMany([
        ImItem(0, "A", 10, true),
        ImItem(0, "B", 20, true),
    ]);

    assert(more.length == 2);
    assert(more[0].id != first.id);
    assert(more[1].id != first.id);
    assert(more[0].id != more[1].id);
    assert(repo.query().count() == 3);
}
