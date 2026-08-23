/** INSERT … ON CONFLICT: actions, targets, and partial-index inference.
  *
  * Two things are covered here:
  *
  *  - `insert!(OnConflict.doNothing, …)` returns Nullable!M, empty when a
  *    conflicting row already existed. That return type is forced, not chosen:
  *    DO NOTHING yields no row, so it cannot share insert()'s signature.
  *
  *  - A PARTIAL unique index (`@uniqueIndex(where: …)`) can only be inferred
  *    when the statement repeats the index predicate. Without that, a model
  *    declaring one had no working upsert at all — PostgreSQL answers
  *    "there is no unique or exclusion constraint matching the ON CONFLICT
  *    specification". The predicate is emitted automatically, so both the long
  *    and the short spelling work.
  **/
module peque.orm.tests.on_conflict;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.algorithm.searching: canFind;

private import peque.connection: Connection;
private import peque.exception: QueryServerError;
private import peque.model: model, field, primaryKey, unique, uniqueIndex,
    uniqueIndexTogether, autoHydrate;
private import peque.orm;


@model("oc_user")
private struct OcUser {
    @primaryKey    int    id;
    @field @unique string email;
    @field         string name;
    @field         int    n;
}

// The unique index is PARTIAL: only live rows must have distinct slugs.
@model("oc_doc")
private struct OcDoc {
    @primaryKey                               int    id;
    @field @uniqueIndex(where: "NOT deleted") string slug;
    @field                                    bool   deleted;
    @field                                    int    n;
}

// Multi-column partial unique index, declared at model level.
@model("oc_multi")
@(uniqueIndexTogether!("tenant_id", "code")(where: "active"))
private struct OcMulti {
    @primaryKey int    id;
    @field      int    tenantId;
    @field      string code;
    @field      bool   active;
    @field      int    n;
}

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
    foreach (t; ["oc_user", "oc_doc", "oc_multi"])
        c.exec(`DROP TABLE IF EXISTS ` ~ t);
    c.exec(modelDDL!OcUser());
    c.exec(modelDDL!OcDoc());
    c.exec(modelDDL!OcMulti());
}


// ---------------------------------------------------------------------------
// P1 — DO NOTHING
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(OcUser, Connection)(&c);

    // Untargeted: any conflict counts.
    OcUser a; a.email = "x@y"; a.name = "first"; a.n = 1;
    auto inserted = repo.insert!(OnConflict.doNothing)(a);
    assert(!inserted.isNull, "a non-conflicting insert must yield the row");
    assert(inserted.get.id > 0 && inserted.get.name == "first");

    OcUser b; b.email = "x@y"; b.name = "second"; b.n = 2;
    auto ignored = repo.insert!(OnConflict.doNothing)(b);
    assert(ignored.isNull, "a conflicting insert must yield nothing");

    // The existing row is untouched — DO NOTHING updates nothing.
    auto rows = repo.query().where!"email"("x@y").all();
    assert(rows.length == 1);
    assert(rows[0].name == "first" && rows[0].n == 1);

    // Targeted at the same unique column: same outcome.
    OcUser d; d.email = "x@y"; d.name = "third"; d.n = 3;
    assert(repo.insert!(OnConflict.doNothing, Target.columns!("email"))(d).isNull);
    assert(repo.query().count() == 1);

    // A different email is not a conflict.
    OcUser e; e.email = "z@y"; e.name = "other"; e.n = 4;
    assert(!repo.insert!(OnConflict.doNothing, Target.columns!("email"))(e).isNull);
    assert(repo.query().count() == 2);
}

unittest {
    // DO UPDATE needs a target: PostgreSQL cannot know what to set without one.
    alias Repo = Repository!(OcUser, Connection);
    static assert( __traits(compiles,
        Repo.init.insert!(OnConflict.doNothing)(*(new OcUser))));
    static assert(!__traits(compiles,
        Repo.init.insert!(OnConflict.doUpdate)(*(new OcUser))),
        "untargeted DO UPDATE must be rejected at compile time");

    // Return types differ, which is the whole reason this is template dispatch.
    static assert(is(typeof(Repo.init.insert(*(new OcUser))) == OcUser));
    static assert(is(typeof(Repo.init.insert!(OnConflict.doNothing)(*(new OcUser)))
                     == Nullable!OcUser));
    static assert(is(typeof(Repo.init.insert!(OnConflict.doUpdate,
                     Target.columns!("email"))(*(new OcUser))) == OcUser));

    // Target.columns! takes D field names; a non-field is a compile error.
    static assert(!__traits(compiles,
        Repo.init.insert!(OnConflict.doNothing, Target.columns!("nosuchfield"))(
            *(new OcUser))));
}


// ---------------------------------------------------------------------------
// P2 — partial unique index inference
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(OcDoc, Connection)(&c);

    OcDoc first; first.slug = "s"; first.n = 1;
    auto seeded = repo.insert(first);
    assert(seeded.n == 1);

    // Long spelling. Without the index predicate this raises
    // "there is no unique or exclusion constraint matching …".
    OcDoc up; up.slug = "s"; up.n = 42;
    auto updated = repo.insert!(OnConflict.doUpdate, Target.columns!("slug"))(up);
    assert(updated.n == 42, "DO UPDATE must target the partial unique index");
    assert(repo.query().count() == 1, "it must update, not insert a second row");

    // Short spelling must reach the same index.
    OcDoc up2; up2.slug = "s"; up2.n = 99;
    assert(repo.upsert!"slug"(up2).n == 99);
    assert(repo.query().count() == 1);

    // DO NOTHING targeting the same partial index.
    OcDoc ig; ig.slug = "s"; ig.n = 7;
    assert(repo.insert!(OnConflict.doNothing, Target.columns!("slug"))(ig).isNull);
    assert(repo.query().all()[0].n == 99, "DO NOTHING must not overwrite");

    // The index excludes deleted rows, so a deleted row does not conflict —
    // proving the emitted predicate really is the index's, not a no-op.
    OcDoc del; del.slug = "s"; del.deleted = true; del.n = 5;
    repo.insert(del);
    assert(repo.query().count() == 2);
}

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(OcMulti, Connection)(&c);

    OcMulti a; a.tenantId = 1; a.code = "c"; a.active = true; a.n = 1;
    repo.insert(a);

    // Multi-column partial index, matched as a set.
    OcMulti b; b.tenantId = 1; b.code = "c"; b.active = true; b.n = 2;
    auto r = repo.insert!(OnConflict.doUpdate, Target.columns!("tenantId", "code"))(b);
    assert(r.n == 2);
    assert(repo.query().count() == 1);

    // Column order in the target must not matter — index inference is a set.
    OcMulti d; d.tenantId = 1; d.code = "c"; d.active = true; d.n = 3;
    auto r2 = repo.insert!(OnConflict.doUpdate, Target.columns!("code", "tenantId"))(d);
    assert(r2.n == 3);
    assert(repo.query().count() == 1);
}

unittest {
    // A plain (non-partial) unique must NOT gain a WHERE clause.
    auto c = makeConn();
    setup(c);

    static struct SpyCtx {
        Connection* conn;
        static string lastSQL;
        auto exec(string sql) { lastSQL = sql; return conn.exec(sql); }
        auto execParams(T...)(string sql, T args) {
            lastSQL = sql;
            return conn.execParams(sql, args);
        }
    }
    auto spy  = SpyCtx(&c);
    auto repo = Repository!(OcUser, SpyCtx)(&spy);

    OcUser u; u.email = "a@b"; u.name = "n"; u.n = 1;
    repo.insert!(OnConflict.doUpdate, Target.columns!("email"))(u);
    assert(SpyCtx.lastSQL.canFind(`ON CONFLICT ("email") DO UPDATE`), SpyCtx.lastSQL);
    assert(!SpyCtx.lastSQL.canFind("WHERE"), SpyCtx.lastSQL);

    auto docRepo = Repository!(OcDoc, SpyCtx)(&spy);
    OcDoc d; d.slug = "s"; d.n = 1;
    docRepo.insert!(OnConflict.doUpdate, Target.columns!("slug"))(d);
    assert(SpyCtx.lastSQL.canFind(`ON CONFLICT ("slug") WHERE NOT deleted DO UPDATE`),
        SpyCtx.lastSQL);
}


// ---------------------------------------------------------------------------
// P3 — explicit constraint target
//
// Needed when inference is ambiguous, or when the constraint is not expressible
// as a column list. For a constraint target peque cannot know which columns the
// constraint covers, so DO UPDATE SET spans every non-PK column; re-setting a
// key column to EXCLUDED's value is a no-op, since that is what it conflicted on.
// ---------------------------------------------------------------------------

@model("oc_named")
@uniqueTogether!("tenant_id", "code")
private struct OcNamed {
    @primaryKey int    id;
    @field      int    tenantId;
    @field      string code;
    @field      int    n;
}

unittest {
    import std.algorithm.searching: canFind;

    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS oc_named`);
    c.exec(modelDDL!OcNamed());

    // PostgreSQL derives the constraint name from table + columns; confirm it
    // rather than hard-coding a guess.
    auto meta = c.exec(`SELECT conname FROM pg_constraint
                        WHERE conrelid = 'oc_named'::regclass AND contype = 'u'`);
    assert(meta.ntuples == 1);
    assert(meta.getRow(0)[0].as!string == "oc_named_tenant_id_code_key");

    auto repo = Repository!(OcNamed, Connection)(&c);
    OcNamed a; a.tenantId = 1; a.code = "x"; a.n = 1;
    repo.insert(a);

    OcNamed b; b.tenantId = 1; b.code = "x"; b.n = 2;
    auto up = repo.insert!(OnConflict.doUpdate,
                           Target.constraint!("oc_named_tenant_id_code_key"))(b);
    assert(up.n == 2);
    assert(repo.query().count() == 1);

    OcNamed d; d.tenantId = 1; d.code = "x"; d.n = 3;
    auto ig = repo.insert!(OnConflict.doNothing,
                           Target.constraint!("oc_named_tenant_id_code_key"))(d);
    assert(ig.isNull);
    assert(repo.query().all()[0].n == 2, "DO NOTHING must not overwrite");

    // A constraint that does not exist is a server error, not silent success —
    // the name is not checkable at compile time the way a field name is.
    OcNamed e; e.tenantId = 1; e.code = "x"; e.n = 4;
    bool threw = false;
    try
        repo.insert!(OnConflict.doNothing, Target.constraint!("no_such_constraint"))(e);
    catch (QueryServerError)
        threw = true;
    assert(threw, "an unknown constraint name must surface as a server error");

    c.exec(`DROP TABLE IF EXISTS oc_named`);
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
    c.exec(`DROP TABLE IF EXISTS oc_named`);
    c.exec(modelDDL!OcNamed());

    auto spy  = SpyCtx(&c);
    auto repo = Repository!(OcNamed, SpyCtx)(&spy);
    OcNamed a; a.tenantId = 1; a.code = "x"; a.n = 1;
    repo.insert!(OnConflict.doNothing, Target.constraint!("oc_named_tenant_id_code_key"))(a);

    // The constraint name is an identifier and must be quoted, not spliced bare.
    assert(SpyCtx.lastSQL.canFind(
        `ON CONFLICT ON CONSTRAINT "oc_named_tenant_id_code_key" DO NOTHING`),
        SpyCtx.lastSQL);

    c.exec(`DROP TABLE IF EXISTS oc_named`);
}
