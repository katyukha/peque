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
private import std.typecons: Nullable, nullable;
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
// F!(M,"field").contains() — typed IN predicate
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    // string field IN list
    auto r = repo.query()
        .where(F!(WtItem, "status").contains(["active", "inactive"]))
        .all();
    assert(r.length == 3);   // Alpha, Gamma, Delta
    foreach (ri; r) assert(ri.status != "pending");

    // int field IN list
    auto r2 = repo.query()
        .where(F!(WtItem, "score").contains([10, 50]))
        .all();
    assert(r2.length == 2);

    // empty list → always-false, no rows
    auto r3 = repo.query()
        .where(F!(WtItem, "status").contains(cast(string[])[]))
        .all();
    assert(r3.length == 0);
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
// F!(M,"field").ilike()
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(WtItem, Connection)(&c);

    auto r = repo.query().where(F!(WtItem, "name").ilike("g%")).all();
    assert(r.length == 1);
    assert(r[0].name == "Gamma");

    auto r2 = repo.query().where(F!(WtItem, "name").ilike("%A%")).all();
    assert(r2.length == 4);  // Alpha, Beta, Gamma, Delta (all contain 'a'/'A')
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


// ---------------------------------------------------------------------------
// Column-to-column comparisons
//
// Equality and != accepted another F! already; the ordering operators did not,
// so `use_count < max_uses` had to be written as whereRaw. That works but
// embeds the column names literally, surviving an @field rename that these
// overloads catch.
//
// No type-compatibility check is imposed. D's own comparability is the wrong
// test for SQL: `Nullable!int < int` and `Date < SysTime` are both false in D
// and both fine in PostgreSQL.
// ---------------------------------------------------------------------------

@model("wt_tenant")
private struct WtTenant {
    @primaryKey int id;
    @field      int quota;
}

@model("wt_invite")
private struct WtInvite {
    @primaryKey          int          id;
    @field               string       code;
    @field               int          useCount;
    @field               int          maxUses;
    @field               Nullable!int spare;
    @many2one!(WtTenant) Nullable!int tenantId;
    @related("tenantId") Nullable!WtTenant tenant;
}

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS wt_invite`);
    c.exec(`DROP TABLE IF EXISTS wt_tenant`);
    c.exec(modelDDL!WtTenant());
    c.exec(modelDDL!WtInvite());

    auto tSeed = WtTenant(0, 10);
    auto tenant = Repository!(WtTenant, Connection)(&c).insert(tSeed);
    auto repo = Repository!(WtInvite, Connection)(&c);

    void mk(string code, int used, int max, Nullable!int spare) {
        WtInvite i;
        i.code = code; i.useCount = used; i.maxUses = max;
        i.spare = spare; i.tenantId = tenant.id.nullable;
        repo.insert(i);
    }
    mk("usable",    1, 5, 3.nullable);
    mk("exhausted", 5, 5, 3.nullable);
    mk("over",      7, 5, 3.nullable);
    mk("nullspare", 1, 5, Nullable!int.init);

    // The case this was added for.
    auto usable = repo.query()
        .where(F!(WtInvite, "useCount").lt(F!(WtInvite, "maxUses")))
        .orderBy!("code")().all();
    assert(usable.length == 2, "use_count < max_uses");
    assert(usable[0].code == "nullspare" && usable[1].code == "usable");

    // Each operator, against the same fixture.
    assert(repo.query().where(F!(WtInvite,"useCount").lte(F!(WtInvite,"maxUses"))).count() == 3);
    assert(repo.query().where(F!(WtInvite,"useCount").gt (F!(WtInvite,"maxUses"))).count() == 1);
    assert(repo.query().where(F!(WtInvite,"useCount").gte(F!(WtInvite,"maxUses"))).count() == 2);
    assert(repo.query().where(F!(WtInvite,"useCount").ne (F!(WtInvite,"maxUses"))).count() == 3);
    assert(repo.query().where(F!(WtInvite,"useCount")   (F!(WtInvite,"maxUses"))).count() == 1);

    // Three-valued logic: a NULL on either side excludes the row, exactly as
    // for .ne() and as Django's F() expressions behave.
    assert(repo.query().where(F!(WtInvite,"spare").lt(F!(WtInvite,"maxUses"))).count() == 3,
        "the NULL-spare row must not match");

    // Type-free spelling resolves the same way.
    assert(repo.query().where(F!"useCount".lt(F!"maxUses")).count() == 2);

    // Path-to-path: both sides joined columns, join emitted once.
    assert(repo.query().where(F!"tenant.quota".gt(F!"tenant.quota")).count() == 0);
    assert(repo.query().where(F!"tenant.quota".gte(F!"tenant.quota")).count() == 4);

    c.exec(`DROP TABLE IF EXISTS wt_invite`);
    c.exec(`DROP TABLE IF EXISTS wt_tenant`);
}

unittest {
    // Mixed field/path comparison is not supported — and never was, for equality
    // or != either. FieldBuilder carries an already-resolved column expression
    // while PathBuilder carries an unresolved path, so there is no node holding
    // one of each. A compile error, not silently wrong SQL.
    static assert(!__traits(compiles, F!"useCount".lt(F!"tenant.quota")));
    static assert(!__traits(compiles, F!"useCount".ne(F!"tenant.quota")));
    static assert(!__traits(compiles, F!"useCount"(F!"tenant.quota")));
    static assert(!__traits(compiles, F!"tenant.quota".lt(F!"useCount")));

    // Controls: both same-kind forms do compile.
    static assert(__traits(compiles, F!"useCount".lt(F!"maxUses")));
    static assert(__traits(compiles, F!"tenant.quota".lt(F!"tenant.quota")));
}


// ---------------------------------------------------------------------------
// Arithmetic expressions in WHERE
//
// F!"a" + 1 already worked on the SET side of update(); the same expression now
// works as a comparison operand. A SetExpr is a self-contained (SQL, params)
// pair with 1-based placeholders, so RawNode carries it and the serializer
// renumbers it like any other bound fragment — the case worth testing is an
// expression sharing a statement with other bound values.
// ---------------------------------------------------------------------------

@model("wt_job")
private struct WtJob {
    @primaryKey int id;
    @field      int attempts;
    @field      int maxAttempts;
    @field      int backoff;
}

unittest {
    import std.algorithm.searching: canFind;

    static struct SpyCtx {
        Connection* conn;
        static string lastSQL;
        auto exec(string sql) { lastSQL = sql; return conn.exec(sql); }
        auto execParams(T...)(string sql, T args) {
            lastSQL = sql;
            return conn.execParams(sql, args);
        }
    }

    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS wt_job`);
    c.exec(modelDDL!WtJob());

    auto spy  = SpyCtx(&c);
    auto repo = Repository!(WtJob, SpyCtx)(&spy);
    void mk(int a, int m, int b) {
        WtJob j; j.attempts = a; j.maxAttempts = m; j.backoff = b;
        repo.insert(j);
    }
    mk(1, 3, 10);
    mk(3, 3, 20);
    mk(2, 3, 30);

    alias J = WtJob;

    // Expression on the left, compared to a column.
    assert(repo.query().where((F!(J,"attempts") + 1).lte(F!(J,"maxAttempts"))).count() == 2);
    assert(SpyCtx.lastSQL.canFind(`(_m."attempts" + $1) <= _m."max_attempts"`), SpyCtx.lastSQL);

    // Expression on the right of a field comparison. Operands are swapped so
    // both orderings share one SQL shape; the meaning is unchanged.
    assert(repo.query().where(F!(J,"attempts").lt(F!(J,"maxAttempts") + 1)).count() == 3);

    // Expression compared to a plain value.
    assert(repo.query().where((F!(J,"attempts") + 1).lte(3)).count() == 2);

    // Numbering: a bound value earlier in the statement must not collide with
    // the expression's own placeholder.
    assert(repo.query().where!"backoff"(10)
               .where((F!(J,"attempts") + 1).lte(F!(J,"maxAttempts"))).count() == 1);
    assert(SpyCtx.lastSQL.canFind(`_m."backoff" = $1`) &&
           SpyCtx.lastSQL.canFind(`(_m."attempts" + $2)`), SpyCtx.lastSQL);

    // Two expressions, each carrying a parameter.
    assert(repo.query().where((F!(J,"attempts") + 1).lte(F!(J,"maxAttempts") + 2)).count() == 3);
    assert(SpyCtx.lastSQL.canFind(`(_m."attempts" + $1) <= (_m."max_attempts" + $2)`),
           SpyCtx.lastSQL);

    // Every operator, and composition with the boolean combinators.
    assert(repo.query().where((F!(J,"attempts") * 2).gt(F!(J,"maxAttempts"))).count() == 2);
    assert(repo.query().where((F!(J,"attempts") + 0)(F!(J,"maxAttempts"))).count() == 1);
    assert(repo.query().where((F!(J,"attempts") + 0).ne(F!(J,"maxAttempts"))).count() == 2);
    assert(repo.query()
               .where((F!(J,"attempts") + 1).lte(F!(J,"maxAttempts")) &
                      F!(J,"backoff").gt(15)).count() == 1);

    // The same expression still drives update()'s SET side.
    assert(repo.query().where!"backoff"(10).set!"attempts"(F!"attempts" + 5).update() == 1);
    assert(repo.query().where!"backoff"(10).first().get.attempts == 6);

    c.exec(`DROP TABLE IF EXISTS wt_job`);
}
