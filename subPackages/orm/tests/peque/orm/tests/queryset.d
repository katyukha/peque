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
private import peque.model: model, field, primaryKey, defaultOrder, many2one, related;
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
// whereRaw with zero bound parameters — hardcoded SQL fragment, no $N
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    // No placeholders — the parameter renumbering logic must handle empty args.
    auto all = repo.query().whereRaw("1=1").all();
    assert(all.length == 4, "whereRaw with no params must not discard any rows");

    // Combine with a typed filter to verify param numbering still works after.
    auto active = repo.query()
                      .whereRaw("1=1")
                      .whereRaw("active = $1", true)
                      .all();
    assert(active.length == 2);
}


// ---------------------------------------------------------------------------
// whereIn with an empty slice — must return zero rows (SQL: WHERE FALSE)
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    // An empty value list is equivalent to Predicate.none — the query must
    // return zero rows without hitting the DB with invalid "IN ()" SQL.
    string[] empty;
    assert(repo.query().whereIn!"name"(empty).all().length == 0);
}


// ---------------------------------------------------------------------------
// Predicate.none / Predicate.all / qs.none()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    // .none predicate — always false → zero rows
    assert(repo.query().where(Predicate.none).all().length == 0);
    assert(repo.query().where(Predicate.none).count() == 0);
    assert(repo.query().where(Predicate.none).exists() == false);

    // .all predicate — always true → all rows
    assert(repo.query().where(Predicate.all).all().length == 4);
    assert(repo.query().where(Predicate.all).count() == 4);

    // qs.none() convenience sugar
    assert(repo.query().none().all().length == 0);
    assert(repo.query().none().count() == 0);

    // Combining with real filters: none | pred == pred (identity for OR)
    auto active = repo.query()
        .where(Predicate.none | F!(Item, "active")(true))
        .all();
    assert(active.length == 2);
    foreach (r; active) assert(r.active == true);

    // Combining with real filters: all & pred == pred (identity for AND)
    auto highScore = repo.query()
        .where(Predicate.all & F!(Item, "score").gte(30))
        .all();
    assert(highScore.length == 2);
}


// ---------------------------------------------------------------------------
// update() with no set!() calls — must throw PequeException, not assert
// ---------------------------------------------------------------------------

unittest {
    import std.exception: assertThrown;
    import peque.exception: PequeException;

    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(Item, Connection)(&c);

    repo.query().update().assertThrown!PequeException;
    repo.query().where!"active"(true).update().assertThrown!PequeException;
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


// ---------------------------------------------------------------------------
// ORDER BY: typed F! terms, raw-string escape hatch, compile-time orderBy!,
// NULLS placement, and typed @defaultOrder. All paths share one resolver.
// ---------------------------------------------------------------------------

@model("qs_ordered")
@defaultOrder!(F!"sortKey")          // typed default order: ASC by the sortKey column
struct Ordered {
    @primaryKey int          id;
    @field      string       name;
    @field      int          sortKey;
    @field      Nullable!int rank;
}

alias QsOrderedReg = Registry!(Bind!(Ordered, ModelRepo!Ordered));

private void seedOrdered(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS qs_ordered;");
    c.exec(schemaSQL!QsOrderedReg());

    auto repo = Repository!(Ordered, Connection)(&c);
    foreach (row; [
        Ordered(0, "c", 30, Nullable!int(3)),
        Ordered(0, "a", 10, Nullable!int.init),   // NULL rank
        Ordered(0, "b", 20, Nullable!int(1)),
    ])
        repo.insert(row);
}

// @defaultOrder!(F!"sortKey") applies with no explicit orderBy(); the camelCase
// field name resolves to the sortKey column. findAll() shares the same path.
unittest {
    auto c = makeConn(); seedOrdered(c);
    auto repo = Repository!(Ordered, Connection)(&c);

    auto rows = repo.query().all();
    assert(rows[0].sortKey == 10);
    assert(rows[1].sortKey == 20);
    assert(rows[2].sortKey == 30);

    auto viaFindAll = repo.findAll();
    assert(viaFindAll[0].sortKey == 10);
    assert(viaFindAll[$-1].sortKey == 30);
}

// Runtime orderBy with F! terms — bare = ASC, .desc = DESC, multiple terms.
unittest {
    auto c = makeConn(); seedOrdered(c);
    auto repo = Repository!(Ordered, Connection)(&c);

    auto desc = repo.query().orderBy(F!"sortKey".desc).all();
    assert(desc[0].sortKey == 30 && desc[$-1].sortKey == 10);

    auto asc = repo.query().orderBy(F!"sortKey").all();
    assert(asc[0].sortKey == 10);

    auto multi = repo.query().orderBy(F!"name".desc, F!"id").all();
    assert(multi[0].name == "c");
    assert(multi[$-1].name == "a");
}

// Raw string is emitted verbatim — the escape hatch for SQL expressions.
unittest {
    auto c = makeConn(); seedOrdered(c);
    auto repo = Repository!(Ordered, Connection)(&c);

    auto rows = repo.query().orderBy(`"sortKey" DESC`).all();
    assert(rows[0].sortKey == 30);

    auto byExpr = repo.query().orderBy("lower(name) ASC").all();
    assert(byExpr[0].name == "a");

    // A single "" suppresses ordering (overrides @defaultOrder).
    assert(repo.query().orderBy("").all().length == 3);
}

// Compile-time-validated orderBy!("-field") — leading '-' is descending.
unittest {
    auto c = makeConn(); seedOrdered(c);
    auto repo = Repository!(Ordered, Connection)(&c);

    auto desc = repo.query().orderBy!("-sortKey").all();
    assert(desc[0].sortKey == 30);

    auto two = repo.query().orderBy!("-sortKey", "name").all();
    assert(two[0].sortKey == 30);

    // An unknown field name fails to compile.
    static assert(!__traits(compiles, repo.query().orderBy!("notAField")));
    // Raw SQL / whitespace is rejected by orderBy! (use runtime orderBy for raw).
    static assert(!__traits(compiles, repo.query().orderBy!("sortKey DESC")));
    // Passing an F!/Ordering to orderBy! (the '!') is a mistake — caught clearly.
    static assert(!__traits(compiles, repo.query().orderBy!(F!"sortKey".desc)));
    // …the same value works through the runtime form.
    assert(repo.query().orderBy(F!"sortKey".desc).all()[0].sortKey == 30);
}

// NULLS FIRST / NULLS LAST placement on a nullable column.
unittest {
    auto c = makeConn(); seedOrdered(c);
    auto repo = Repository!(Ordered, Connection)(&c);

    auto nf = repo.query().orderBy(F!"rank".asc.nullsFirst).all();
    assert(nf[0].rank.isNull);

    auto nl = repo.query().orderBy(F!"rank".asc.nullsLast).all();
    assert(nl[$-1].rank.isNull);
}


// ---------------------------------------------------------------------------
// 2-level join-path ordering (O3A → b → c.label). Exercises the unified
// _resolveTwoLevel / _pathRelType / _pathFkCol resolver and the 2-level branch
// of _assertOrderPath (compile-time orderBy! validation).
// ---------------------------------------------------------------------------

@model("o3_c")
struct O3C {
    @primaryKey int    id;
    @field      string label;
}

@model("o3_b")
struct O3B {
    @primaryKey            int          id;
    @field                 string       name;
    @many2one!(O3C)        Nullable!int cId;
    @related               Nullable!O3C c;
}

@model("o3_a")
struct O3A {
    @primaryKey            int          id;
    @field                 string       title;
    @many2one!(O3B)        Nullable!int bId;
    @related               Nullable!O3B b;
}

// Referenced tables first so FK REFERENCES resolve.
alias O3Reg = Registry!(
    Bind!(O3C, ModelRepo!O3C),
    Bind!(O3B, ModelRepo!O3B),
    Bind!(O3A, ModelRepo!O3A),
);

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS o3_a; DROP TABLE IF EXISTS o3_b; DROP TABLE IF EXISTS o3_c;");
    c.exec(schemaSQL!O3Reg());

    auto cRepo = Repository!(O3C, Connection)(&c);
    auto bRepo = Repository!(O3B, Connection)(&c);
    auto aRepo = Repository!(O3A, Connection)(&c);

    auto cz = O3C(0, "Zeta");  auto ca = O3C(0, "Alpha");
    auto cZeta  = cRepo.insert(cz);
    auto cAlpha = cRepo.insert(ca);
    auto b1r = O3B(0, "B1", Nullable!int(cZeta.id));
    auto b2r = O3B(0, "B2", Nullable!int(cAlpha.id));
    auto b1 = bRepo.insert(b1r);
    auto b2 = bRepo.insert(b2r);
    auto a1r = O3A(0, "A1", Nullable!int(b1.id));   // → c.label = Zeta
    auto a2r = O3A(0, "A2", Nullable!int(b2.id));   // → c.label = Alpha
    aRepo.insert(a1r);
    aRepo.insert(a2r);

    // Runtime F path: ORDER BY c.label ASC → Alpha (A2) before Zeta (A1).
    auto byF = aRepo.query().orderBy(F!"b.c.label").all();
    assert(byF[0].title == "A2");
    assert(byF[1].title == "A1");

    // Compile-time-validated 2-level path, descending.
    auto byCt = aRepo.query().orderBy!("-b.c.label").all();
    assert(byCt[0].title == "A1");   // Zeta first (DESC)
    assert(byCt[1].title == "A2");

    // Bad leaf / bad intermediate relation are caught at compile time.
    static assert(!__traits(compiles, aRepo.query().orderBy!("b.c.nosuchcol")));
    static assert(!__traits(compiles, aRepo.query().orderBy!("b.nosuchrel.label")));
}
