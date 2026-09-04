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
private import std.exception: assertThrown;
private import std.typecons: Nullable, nullable;
private import std.datetime: SysTime;
private import peque.connection: Connection;
private import peque.exception: QueryClientError;
private import peque.model: model, field, primaryKey, many2one, related;
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
    import peque.exception: PequeException;

    auto c    = makeConn();
    auto rows = seed(c);
    auto repo = Repository!(QuItem, Connection)(&c);

    // Calling update() without any set!() is a programming error —
    // it would generate "UPDATE ... SET  WHERE ..." which is invalid SQL.
    assertThrown!PequeException(
        repo.query().whereRaw("id = $1", rows[0].id).update(),
        "update() with no set!() calls must throw PequeException");
}


// ---------------------------------------------------------------------------
// setRaw! — a column computed from an expression rather than a bound value
// ---------------------------------------------------------------------------

@model("qsr_partner")
struct QsrPartner {
    @primaryKey int    id;
    @field      string name;
}

@model("qsr_job")
struct QsrJob {
    @primaryKey             int             id;
    @field                  string          state;
    @field                  int             attempts;
    @field                  int             backoff;
    @field                  Nullable!SysTime lockedAt;
    @many2one!(QsrPartner)  Nullable!int    partnerId;
    @related                Nullable!QsrPartner partner;
}

alias QsrReg = Registry!(
    Bind!(QsrPartner, ModelRepo!QsrPartner),
    Bind!(QsrJob,     ModelRepo!QsrJob),
);

private Repository!(QsrJob, Connection) seedJobs(ref Connection c) {
    c.exec(`DROP TABLE IF EXISTS qsr_job`);
    c.exec(`DROP TABLE IF EXISTS qsr_partner`);
    c.exec(schemaSQL!QsrReg());

    auto pRepo = Repository!(QsrPartner, Connection)(&c);
    auto p     = QsrPartner(0, "acme");
    auto saved = pRepo.insert(p);

    auto repo = Repository!(QsrJob, Connection)(&c);
    foreach (i; 0 .. 3) {
        QsrJob j;
        j.state     = "queued";
        j.attempts  = i;
        j.backoff   = 100;
        j.partnerId = saved.id.nullable;
        repo.insert(j);
    }
    return repo;
}

// A column computed from its own current value, and a server-side function —
// neither expressible with set!(), which binds a value.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    immutable n = repo.query()
        .setRaw!"attempts"("attempts + 1")
        .setRaw!"lockedAt"("now()")
        .update();
    assert(n == 3);

    auto jobs = repo.query().orderBy!("attempts")().all();
    assert(jobs[0].attempts == 1);      // was 0
    assert(jobs[1].attempts == 2);      // was 1
    assert(jobs[2].attempts == 3);      // was 2
    foreach (ref j; jobs)
        assert(!j.lockedAt.isNull && j.lockedAt.get.year >= 2020);
}

// Bound values inside an expression, interleaved with plain set!() — the
// placeholder numbering has to account for expressions binding 0, 1 or more.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    immutable n = repo.query().where!"state"("queued")
        .setRaw!"attempts"("attempts + 1")             // binds nothing
        .set!"state"("running")                        // binds one
        .setRaw!"backoff"("LEAST(backoff * $1, $2)", 4, 250)   // binds two
        .update();
    assert(n == 3);

    auto jobs = repo.query().orderBy!("attempts")().all();
    assert(jobs[0].attempts == 1);
    assert(jobs[0].state == "running");
    assert(jobs[0].backoff == 250);     // LEAST(100*4, 250)
}

// The joins branch: with a relation-path predicate the UPDATE target carries no
// alias, so an expression must still resolve. This is the case where a
// `_m.`-qualified reference would fail while the plain one works.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    immutable n = repo.query()
        .where(F!"partner.name"("acme"))
        .setRaw!"attempts"("attempts + 10")
        .update();
    assert(n == 3, "expression SET must work in the joined-update branch too");

    auto jobs = repo.query().orderBy!("attempts")().all();
    assert(jobs[0].attempts == 10);
}

// Last-write-wins applies across both forms, so a column never gets two
// assignments (which PostgreSQL rejects outright).
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    immutable n = repo.query()
        .setRaw!"attempts"("attempts + 100")
        .set!"attempts"(7)                  // supersedes the expression
        .update();
    assert(n == 3);
    foreach (ref j; repo.query().all()) assert(j.attempts == 7);

    immutable n2 = repo.query()
        .set!"attempts"(1)
        .setRaw!"attempts"("attempts + 5")  // supersedes the value
        .update();
    assert(n2 == 3);
    foreach (ref j; repo.query().all()) assert(j.attempts == 12);
}

// The UPDATE target is aliased _m in both shapes, so a column may be referenced
// bare or qualified and resolves the same way — including in the joined shape,
// where the subquery's own _m shadows the target's.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    assert(repo.query().setRaw!"attempts"("_m.attempts + 1").update() == 3);
    foreach (ref j; repo.query().orderBy!("attempts")().all())
        assert(j.attempts >= 1);

    assert(repo.query().where(F!"partner.name"("acme"))
               .setRaw!"attempts"("_m.attempts + 1").update() == 3,
        "a qualified reference must resolve in the joined shape too");

    assertThrown!QueryClientError(
        repo.query().setRaw!"attempts"("").update());

    // A non-column field is still a compile-time error.
    static assert(!__traits(compiles,
        repo.query().setRaw!"partner"("x").update()));
}


// ---------------------------------------------------------------------------
// set!(expression) — arithmetic on field builders
// ---------------------------------------------------------------------------

// Operands are bound rather than inlined, so an expression is injection-safe
// however it was composed. Only arithmetic is available as an operator: D
// routes comparisons through opCmp, which must return int.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);   // attempts 0,1,2  backoff 100

    assert(repo.query().set!"attempts"(F!"attempts" + 1).update() == 3);
    auto a = repo.query().orderBy!("attempts")().all();
    assert(a[0].attempts == 1 && a[1].attempts == 2 && a[2].attempts == 3);

    // Composition, and the parameters of each operand renumbered on the way.
    assert(repo.query().set!"backoff"((F!"backoff" + 10) * 2).update() == 3);
    assert(repo.query().all()[0].backoff == 220);

    // Value on the left goes through opBinaryRight.
    assert(repo.query().set!"backoff"(1000 - F!"backoff").update() == 3);
    assert(repo.query().all()[0].backoff == 780);

    // Column to column — neither side binds a parameter.
    assert(repo.query().set!"backoff"(F!"backoff" - F!"attempts").update() == 3);
    auto b = repo.query().orderBy!("attempts")().all();
    assert(b[0].backoff == 780 - 1);

    // A bare field builder copies one column into another.
    assert(repo.query().set!"backoff"(F!"attempts").update() == 3);
    foreach (ref j; repo.query().all()) assert(j.backoff == j.attempts);
}

// The typed form validates the column against the model; the type-free form
// does not, matching how F! behaves in predicates.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    assert(repo.query().set!"attempts"(F!(QsrJob, "attempts") * 3).update() == 3);
    auto a = repo.query().orderBy!("attempts")().all();
    assert(a[2].attempts == 6);

    // Arithmetic on a non-numeric column is rejected when the type is known.
    static assert(!__traits(compiles, F!(QsrJob, "state") + 1));
    // …and the plain value form still works for that column.
    assert(repo.query().set!"state"("done").update() == 3);
}

// The joined shape aliases its UPDATE target too, so an expression referring to
// the updated row resolves there as well.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    assert(repo.query().where(F!"partner.name"("acme"))
               .set!"attempts"(F!"attempts" + 100).update() == 3);
    assert(repo.query().orderBy!("attempts")().all()[0].attempts == 100);
}

// Last write wins across all three assignment forms.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    assert(repo.query()
        .set!"attempts"(F!"attempts" + 1000)   // expression
        .setRaw!"attempts"("attempts + 500")   // raw expression
        .set!"attempts"(9)                     // plain value — wins
        .update() == 3);
    foreach (ref j; repo.query().all()) assert(j.attempts == 9);
}


// A SELECT terminal cannot apply assignments, so a forgotten .update() is
// reported rather than returning rows that look like the write succeeded.
unittest {
    auto c    = makeConn();
    auto repo = seedJobs(c);

    assertThrown!QueryClientError(repo.query().set!"attempts"(1).all());
    assertThrown!QueryClientError(repo.query().setRaw!"attempts"("attempts + 1").all());
    assertThrown!QueryClientError(repo.query().set!"attempts"(F!"attempts" + 1).first());

    // count()/exists() do not read the sets and are unaffected.
    assert(repo.query().set!"attempts"(1).count() == 3);

    // Nothing was written by any of the above.
    foreach (ref j; repo.query().all()) assert(j.attempts < 3);
}
