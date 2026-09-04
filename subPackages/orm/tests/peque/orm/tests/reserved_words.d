/** Reserved words and awkward identifiers must survive the whole pipeline.
  *
  * A D field named `order`, `end`, `user` or `check` is perfectly legal and is
  * also a PostgreSQL reserved word. Emitted bare it produces a
  * syntax error far from the model definition — and only in the statements that
  * happen to mention that column, so DDL could succeed while SELECT failed.
  *
  * These tests pin the whole surface: DDL, indexes, CRUD, QuerySet filtering and
  * ordering, joins, DTO projection and aggregation. Any emission point that
  * forgets to quote shows up here as a PostgreSQL syntax error.
  **/
module peque.orm.tests.reserved_words;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.algorithm.searching: canFind;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related,
    autoHydrate, index, unique;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models — "user", "order", "end", "check", "desc", "table" are all reserved
// ---------------------------------------------------------------------------

@model("user")                      // reserved table name
struct RwUser {
    @primaryKey int    id;
    @field      string name;        // not reserved — must stay unquoted
    @field      string desc_;       // "desc_" — not reserved, trailing _
}

@model("order")                     // reserved table name
struct RwOrder {
    @primaryKey           int             id;
    @field                string          title;
    @field         @index  string         check;       // reserved + indexed
    @field                int             end;         // reserved
    @field                Nullable!string window;      // reserved
    @many2one!(RwUser)    Nullable!int    user;        // reserved FK column
    @related("user")      Nullable!RwUser owner;
}

alias RwReg = Registry!(
    Bind!(RwUser,  ModelRepo!RwUser),
    Bind!(RwOrder, ModelRepo!RwOrder),
);

@autoHydrate
struct RwOrderDTO {
    int    id;
    string title;
    int    end;
    @field(related: "owner.name") string ownerName;
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
    c.exec(`DROP TABLE IF EXISTS "order"`);
    c.exec(`DROP TABLE IF EXISTS "user"`);
    c.exec(schemaSQL!RwReg());
}


// ---------------------------------------------------------------------------
// DDL
// ---------------------------------------------------------------------------

unittest {
    enum ddl = schemaSQL!RwReg();

    // Every identifier naming a real database object is quoted, uniformly —
    // reserved or not. That is the whole rule, so there is no keyword list to
    // fall out of date with future PostgreSQL releases.
    assert(ddl.canFind(`CREATE TABLE IF NOT EXISTS "order"`), ddl);
    assert(ddl.canFind(`CREATE TABLE IF NOT EXISTS "user"`),  ddl);
    assert(ddl.canFind(`"end" INTEGER`),  ddl);
    assert(ddl.canFind(`"check" TEXT`),   ddl);
    assert(ddl.canFind(`"window" TEXT`),  ddl);
    assert(ddl.canFind(`"title" TEXT`),   ddl);   // ordinary names too
    assert(ddl.canFind(`"name" TEXT`),    ddl);
    assert(ddl.canFind(`REFERENCES "user"("id")`), ddl);

    // Generated names are peque's own and stay bare: quoting an index name is
    // unnecessary, and quoting a join alias would force the hydration lookup to
    // match case exactly. A quote spliced into either would be invalid.
    assert(ddl.canFind(`idx_order_check ON "order" ("check")`), ddl);
    assert(!ddl.canFind(`idx_"order"`), ddl);
}

unittest {
    // The generated DDL must actually execute.
    auto c = makeConn();
    setup(c);
}


// ---------------------------------------------------------------------------
// CRUD round-trip
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);

    auto userRepo = Repository!(RwUser, Connection)(&c);
    auto uSeed    = RwUser(0, "Ann", "admin");
    auto user     = userRepo.insert(uSeed);
    assert(user.id >= 1);
    assert(user.name == "Ann");

    auto orderRepo = Repository!(RwOrder, Connection)(&c);
    RwOrder oSeed;
    oSeed.title  = "O1";
    oSeed.check  = "pending";
    oSeed.end    = 10;
    oSeed.window = "morning".nullable;
    oSeed.user   = user.id.nullable;
    auto order   = orderRepo.insert(oSeed);

    assert(order.id >= 1);
    assert(order.check == "pending");
    assert(order.end == 10);

    // findById / existsById touch the PK column and the full select list.
    auto found = orderRepo.findById(order.id);
    assert(!found.isNull);
    assert(found.get.title == "O1");
    assert(found.get.end == 10);
    assert(orderRepo.existsById(order.id));

    // update rewrites every non-PK column.
    auto upd = found.get;
    upd.end   = 20;
    upd.check = "done";
    orderRepo.update(upd);
    assert(orderRepo.findById(order.id).get.end == 20);

    // findAll goes through the select list once more.
    assert(orderRepo.findAll().length == 1);
}


// ---------------------------------------------------------------------------
// QuerySet: filtering, ordering, joins, DTO projection, aggregation
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);

    auto userRepo  = Repository!(RwUser, Connection)(&c);
    auto annSeed   = RwUser(0, "Ann", "admin");
    auto bobSeed   = RwUser(0, "Bob", "staff");
    auto ann       = userRepo.insert(annSeed);
    auto bob       = userRepo.insert(bobSeed);

    auto orderRepo = Repository!(RwOrder, Connection)(&c);
    foreach (i, t; ["O1", "O2", "O3"]) {
        RwOrder o;
        o.title = t;
        o.check = (i == 0) ? "pending" : "done";
        o.end   = cast(int)(10 * (i + 1));
        o.user  = (i < 2 ? ann.id : bob.id).nullable;
        orderRepo.insert(o);
    }

    // where! on a reserved column, both by name and via typed F!.
    assert(orderRepo.query().where!"check"("done").count() == 2);
    assert(orderRepo.query().where(F!(RwOrder, "end")(20)).count() == 1);
    assert(orderRepo.query().where(F!(RwOrder, "end").gt(10)).count() == 2);

    // orderBy on a reserved column, compile-time-validated form.
    auto desc = orderRepo.query().orderBy!("-end")().all();
    assert(desc.length == 3);
    assert(desc[0].end == 30 && desc[2].end == 10);

    // Ordering through the F! term builder takes a different code path.
    auto asc = orderRepo.query().orderBy(F!(RwOrder, "end").asc).all();
    assert(asc[0].end == 10);

    // whereIn! and IS NULL on reserved columns.
    assert(orderRepo.query().whereIn!"end"([10, 30]).count() == 2);
    assert(orderRepo.query().where!"window"(Nullable!string.init).count() == 3);

    // Join across a reserved FK column into a reserved table.
    auto joined = orderRepo.query().load!"owner"().orderBy!("end")().all();
    assert(joined.length == 3);
    assert(!joined[0].owner.isNull);
    assert(joined[0].owner.get.name == "Ann");
    assert(joined[2].owner.get.name == "Bob");

    // Relation-path predicate: reserved relation name, reserved target table.
    assert(orderRepo.query().where(F!"owner.name"("Bob")).count() == 1);

    // DTO projection mixes main reserved columns with a joined column.
    auto dtos = orderRepo.query().load!"owner"().orderBy!("end")()
                         .select!RwOrderDTO();
    assert(dtos.length == 3);
    assert(dtos[0].end == 10);
    assert(dtos[0].ownerName == "Ann");

    // Aggregation over a reserved column.
    auto total = orderRepo.query().aggregate!(F!(RwOrder, "end").sum)();
    assert(!total.isNull && total.get == 60);

    // Bulk update / delete on reserved columns.
    assert(orderRepo.query().where!"check"("done").set!"end"(99).update() == 2);
    assert(orderRepo.query().where!"end"(99).count() == 2);
    assert(orderRepo.query().where!"end"(99).delete_() == 2);
    assert(orderRepo.query().count() == 1);
}


// ---------------------------------------------------------------------------
// Case-exact column names
// ---------------------------------------------------------------------------

// @field("MyCol") means the column really is MyCol, since peque quotes every
// identifier. Two things have to agree for that to be usable: the FK column of
// an explicit @related("field") must be quoted like every other identifier, and
// the result lookup must match case-exactly — PQfnumber folds an unquoted name,
// so a bare lookup misses the very column it is looking at.
@model("rw_case_co")
struct RwCaseCo {
    @primaryKey int    id;
    @field      string name;
}

@model("rw_case_t")
struct RwCaseT {
    @primaryKey             int             id;
    @field("MyCol")         string          mixed;
    // The FK column is mixed-case too: that is what exercises the explicit-FK
    // path's quoting. A lowercase FK would work unquoted and hide the bug.
    @field("MyFk") @many2one!(RwCaseCo) Nullable!int coId;
    @related("coId")        Nullable!RwCaseCo co;
}

alias RwCaseReg = Registry!(
    Bind!(RwCaseCo, ModelRepo!RwCaseCo),
    Bind!(RwCaseT,  ModelRepo!RwCaseT),
);

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS rw_case_t`);
    c.exec(`DROP TABLE IF EXISTS rw_case_co`);
    c.exec(schemaSQL!RwCaseReg());

    auto coRepo = Repository!(RwCaseCo, Connection)(&c);
    auto coSeed = RwCaseCo(0, "acme");
    auto co     = coRepo.insert(coSeed);

    auto repo = Repository!(RwCaseT, Connection)(&c);
    RwCaseT t;
    t.mixed = "v";
    t.coId  = co.id.nullable;
    auto saved = repo.insert(t);          // RETURNING hydrates the mixed-case column
    assert(saved.mixed == "v");

    assert(repo.query().all().length == 1);
    assert(repo.query().where!"mixed"("v").count() == 1);

    // The explicit-FK join is a separate emission point from the inferred-FK
    // one, so it needs its own coverage: an unquoted identifier here fails with
    // `column _m.mycol does not exist` while the inferred path still works.
    auto joined = repo.query().load!"co"().all();
    assert(joined.length == 1);
    assert(!joined[0].co.isNull && joined[0].co.get.name == "acme");

    // Relation paths resolve through the same FK.
    assert(repo.query().where(F!"co.name"("acme")).count() == 1);

    c.exec(`DROP TABLE IF EXISTS rw_case_t`);
    c.exec(`DROP TABLE IF EXISTS rw_case_co`);
}


// ---------------------------------------------------------------------------
// D keywords: `@field("version")` on a `version_` member
// ---------------------------------------------------------------------------

// A column can be named after a D keyword, which no member can be. @field is the
// escape hatch: the D side keeps the underscore everywhere — where!, orderBy!,
// the member itself — and only the emitted SQL drops it. Nothing is inferred,
// camelToSnake keeps a trailing underscore.
struct RelDTO { @field("version") int version_; @field string plainName; }

/// Mixing annotated and plain members without @autoHydrate is a compile error.
struct PartlyAnnotatedDTO { @field("version") int version_; string plainName; }

@model("kw_release")
struct KwRelease {
    @primaryKey        int    id;
    @field("version")  int    version_;
    @field("default")  string default_;
    @field("module")   string module_;
    @field             string plainName;
}

unittest {
    import std.algorithm.searching: canFind;

    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS kw_release`);

    // DDL names the SQL column, not the D member.
    enum ddl = modelDDL!KwRelease();
    static assert(ddl.canFind(`"version" INTEGER`), ddl);
    static assert(ddl.canFind(`"default" TEXT`), ddl);
    static assert(ddl.canFind(`"module" TEXT`), ddl);
    static assert(!ddl.canFind(`"version_"`), ddl);
    c.exec(ddl);

    auto repo = Repository!(KwRelease, Connection)(&c);
    KwRelease r;
    r.version_ = 7; r.default_ = "d"; r.module_ = "m"; r.plainName = "p";
    auto ins = repo.insert(r);
    assert(ins.version_ == 7 && ins.default_ == "d" && ins.module_ == "m");

    // Builders take the D member name; the underscore is part of it.
    assert(repo.query().where!"version_"(7).first().get.default_ == "d");
    assert(repo.query().orderBy!("version_")().all().length == 1);
    assert(repo.findById(ins.id).get.module_ == "m");

    // A DTO member follows the same rule.
    auto dto = repo.query().select!RelDTO();
    assert(dto.length == 1 && dto[0].version_ == 7 && dto[0].plainName == "p");

    // A partly-annotated DTO is refused: the unannotated members would be
    // selected and then dropped by the strict hydration path.
    static assert(!__traits(compiles, repo.query().select!PartlyAnnotatedDTO()));

    c.exec(`DROP TABLE IF EXISTS kw_release`);
}
