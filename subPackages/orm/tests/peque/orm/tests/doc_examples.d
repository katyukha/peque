/** The README's ORM examples, compiled.
  *
  * Every example in this file is copied from README.md and must stay in sync
  * with it. The point is not to test ORM behaviour — the rest of the suite does
  * that — but to guarantee the documented code COMPILES and RUNS, because the
  * only reason six documented examples were broken at once is that nothing ever
  * compiled them.
  *
  * Deliberately mirrors the README's own imports: an example that needs an
  * import the README does not show is a broken example.
  **/
module peque.orm.tests.doc_examples;

import std.process: environment;
import std.typecons: Nullable, nullable;
import std.datetime: SysTime, Clock;

import peque;
import peque.orm;


// --- README: "Model definition" ---------------------------------------------

@model("res_partner")
struct Partner {
    @primaryKey int    id;
    @field      string name;
    @field      string email;
    @field      bool   active;
}


// --- README: "Column constraints and indexes" -------------------------------

@model("products")
@uniqueTogether!("name", "tenant_id")
@checkConstraint("chk_price", "price > 0")
@indexTogether!("category_id", "active")
@uniqueIndexTogether!("tenant_id", "slug")
struct Product {
    @primaryKey                                int    id;
    @field @unique @index                      string sku;
    @field @check("price > 0")                 double price;
    @field @pgDefault("true")                  bool   active;
    @field @pgDefault("0") @pgNotNull          Nullable!int stock;
    @field                                     string name;
    @field                                     int    tenantId;
    @field                                     int    categoryId;
    @field @uniqueIndex                        string slug;
}


// --- README: "Column defaults" ----------------------------------------------

@model("doc_partner_defaults")
struct PartnerWithDefaults {
    @primaryKey int     id;
    @field      string  name;
    @field      bool    active = true;      // sent on every insert
    @field      SysTime createdAt;

    void applyDefaults() {
        if (createdAt == SysTime.init) createdAt = Clock.currTime;
    }
}


// --- README: "select!DTO" ---------------------------------------------------

@autoHydrate
struct PartnerSummary { int id; string name; }


// ---------------------------------------------------------------------------

alias DocReg = Registry!(
    Bind!(Partner,             ModelRepo!Partner),
    Bind!(PartnerWithDefaults, ModelRepo!PartnerWithDefaults),
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

// The constraints model is DDL-only here; generating its SQL is enough to prove
// every UDA in that example is reachable from the documented imports.
unittest {
    enum ddl = modelDDL!Product();
    static assert(ddl.length > 0);
}

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS doc_partner_defaults`);
    c.exec(`DROP TABLE IF EXISTS res_partner`);
    c.exec(schemaSQL!DocReg());

    // --- README: "Repository CRUD" ---
    auto repo = Repository!(Partner, Connection)(&c);

    auto seed = Partner(0, "Acme", "acme@example.com", true);
    auto saved = repo.insert(seed);
    assert(saved.id > 0);

    auto found = repo.findById(saved.id);
    assert(!found.isNull);
    assert(repo.existsById(saved.id));
    assert(repo.findAll().length == 1);

    auto upd = found.get;
    upd.name = "Acme Ltd";
    repo.update(upd);

    // --- README: "QuerySet" ---
    auto active   = repo.query().where!"active"(true).all();
    auto ordered  = repo.query().orderBy!("name")().limit(10).all();
    auto count    = repo.query().where!"active"(true).count();
    auto anyLeft  = repo.query().exists();
    auto first    = repo.query().where!"name"("Acme Ltd").first();
    assert(active.length == 1 && ordered.length == 1);
    assert(count == 1 && anyLeft && !first.isNull);

    // --- README: "select!DTO" ---
    PartnerSummary[] summaries = repo.query()
        .where!"active"(true)
        .select!PartnerSummary();
    assert(summaries.length == 1);
    assert(summaries[0].name == "Acme Ltd");

    // --- README: "Type-safe predicates" ---
    auto typed = repo.query()
        .where(F!(Partner, "active")(true) & F!(Partner, "name")("Acme Ltd"))
        .all();
    assert(typed.length == 1);

    // --- README: "Column defaults" ---
    auto defRepo = Repository!(PartnerWithDefaults, Connection)(&c);
    PartnerWithDefaults p;
    p.name = "Defaults";
    auto savedDef = defRepo.insert(p);
    assert(savedDef.active, "a D field initialiser is sent on every insert");
    assert(savedDef.createdAt.year >= 2020, "applyDefaults must run before insert");

    repo.deleteById(saved.id);
    c.exec(`DROP TABLE IF EXISTS doc_partner_defaults`);
    c.exec(`DROP TABLE IF EXISTS res_partner`);
}


// --- README: "Identifier quoting" -------------------------------------------

// Compile-time only: the reserved-words suite owns the "order" table at
// runtime, so this checks the documented shape without racing it.
@model("order")
struct DocOrder {
    @primaryKey int    id;
    @field      string check;
    @field      int    end;
}

unittest {
    import std.algorithm.searching: canFind;
    enum ddl = modelDDL!DocOrder();
    static assert(ddl.canFind(`CREATE TABLE IF NOT EXISTS "order"`), ddl);
    static assert(ddl.canFind(`"check" TEXT`), ddl);
    static assert(ddl.canFind(`"end" INTEGER`), ddl);
}
