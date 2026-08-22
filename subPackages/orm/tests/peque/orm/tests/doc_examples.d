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

// The constraints example is DDL-only, but generating its SQL is not enough:
// @uniqueTogether/@indexTogether take column names as plain strings, so a name
// matching no column still produces a well-formed string. Executing it is what
// makes PostgreSQL check them.
unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS products`);
    c.exec(modelDDL!Product());
    c.exec(`DROP TABLE IF EXISTS products`);
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


// --- README: "Relations" ----------------------------------------------------

@model("doc_tag")
struct Tag {
    @primaryKey int    id;
    @field      string name;
}

@model("doc_res_partner")
struct RelPartner {
    @primaryKey int       id;
    @field      string    name;
    @field      bool      active;

    @one2many!(RelInvoice, "partnerId") RelInvoice[] invoices;
    @many2many!(Tag, "doc_partner_tag_rel", "partner_id", "tag_id") Tag[] tags;
}

@model("doc_account_invoice")
struct RelInvoice {
    @primaryKey           int                 id;
    @field                string              number;
    @many2one!(RelPartner) Nullable!int       partnerId;
    @related              Nullable!RelPartner partner;
}

// Two FKs to the same table: each @related must name its backing field.
@model("doc_shipment")
struct Shipment {
    @primaryKey                   int                 id;
    @field                        string              code;
    @many2one!(RelPartner)        Nullable!int        invoiceAddressId;
    @related("invoiceAddressId")  Nullable!RelPartner invoiceAddress;
    @many2one!(RelPartner)        Nullable!int        deliveryAddressId;
    @related("deliveryAddressId") Nullable!RelPartner deliveryAddress;
}

alias RelReg = Registry!(
    Bind!(Tag,        ModelRepo!Tag),
    Bind!(RelPartner, ModelRepo!RelPartner),
    Bind!(RelInvoice, ModelRepo!RelInvoice),
    Bind!(Shipment,   ModelRepo!Shipment),
);

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS doc_partner_tag_rel`);
    c.exec(`DROP TABLE IF EXISTS doc_shipment`);
    c.exec(`DROP TABLE IF EXISTS doc_account_invoice`);
    c.exec(`DROP TABLE IF EXISTS doc_res_partner`);
    c.exec(`DROP TABLE IF EXISTS doc_tag`);
    c.exec(schemaSQL!RelReg());
    c.exec(`CREATE TABLE doc_partner_tag_rel (
                partner_id int REFERENCES doc_res_partner(id),
                tag_id     int REFERENCES doc_tag(id))`);

    auto partnerRepo = Repository!(RelPartner, Connection)(&c);
    auto invoiceRepo = Repository!(RelInvoice, Connection)(&c);
    auto tagRepo     = Repository!(Tag, Connection)(&c);

    RelPartner acme; acme.name = "Acme"; acme.active = true;
    auto saved = partnerRepo.insert(acme);
    auto tagSeed = Tag(0, "vip");           // insert takes ref M, so an lvalue
    auto tag     = tagRepo.insert(tagSeed);
    c.execParams(`INSERT INTO doc_partner_tag_rel VALUES ($1, $2)`, saved.id, tag.id);

    RelInvoice inv; inv.number = "INV-001"; inv.partnerId = saved.id.nullable;
    invoiceRepo.insert(inv);
    RelInvoice orphan; orphan.number = "INV-ORPHAN";   // NULL FK
    invoiceRepo.insert(orphan);

    // load! — one query, LEFT JOIN
    auto invoices = invoiceRepo.query()
        .load!"partner"()
        .where!"number"("INV-001")
        .all();
    assert(invoices.length == 1);
    assert(!invoices[0].partner.isNull);
    assert(invoices[0].partner.get.name == "Acme");

    // LEFT JOIN, so a NULL FK still yields the row with a null relation.
    auto all = invoiceRepo.query().load!"partner"().all();
    assert(all.length == 2, "LEFT JOIN must keep the NULL-FK row");

    // Relation paths work with or without load!
    assert(invoiceRepo.query().where(F!"partner.name"("Acme")).all().length == 1);
    assert(invoiceRepo.query().orderBy(F!"partner.name".asc).all().length == 2);

    // prefetch! — a second query, no row multiplication
    auto partners = partnerRepo.query()
        .where!"active"(true)
        .prefetch!"invoices"()
        .prefetch!"tags"()
        .all();
    assert(partners.length == 1);
    assert(partners[0].invoices.length == 1);
    assert(partners[0].tags.length == 1);
    assert(partners[0].tags[0].name == "vip");

    // Two FKs to one table, disambiguated by @related("field").
    auto shipRepo = Repository!(Shipment, Connection)(&c);
    Shipment sh; sh.code = "SH-1";
    sh.invoiceAddressId  = saved.id.nullable;
    sh.deliveryAddressId = saved.id.nullable;
    shipRepo.insert(sh);
    auto ships = shipRepo.query().load!"invoiceAddress"().all();
    assert(ships.length == 1 && !ships[0].invoiceAddress.isNull);

    c.exec(`DROP TABLE IF EXISTS doc_partner_tag_rel`);
    c.exec(`DROP TABLE IF EXISTS doc_shipment`);
    c.exec(`DROP TABLE IF EXISTS doc_account_invoice`);
    c.exec(`DROP TABLE IF EXISTS doc_res_partner`);
    c.exec(`DROP TABLE IF EXISTS doc_tag`);
}


// --- README: expression assignments in the QuerySet section -----------------

@model("doc_expr_job")
struct DocExprJob {
    @primaryKey int    id;
    @field      string state;
    @field      int    attempts;
    @field      int    backoff;
}

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS doc_expr_job`);
    c.exec(modelDDL!DocExprJob());

    auto repo = Repository!(DocExprJob, Connection)(&c);
    DocExprJob j; j.state = "queued"; j.attempts = 0; j.backoff = 100;
    repo.insert(j);

    repo.query().where!"state"("queued")
        .set!"attempts"(F!"attempts" + 1)
        .set!"backoff"((F!"backoff" + 10) * 2)
        .update();

    long claimed = repo.query().where!"state"("queued")
        .setRaw!"attempts"("attempts + 1")
        .setRaw!"backoff"("LEAST(backoff * $1, $2)", 4, 3600)
        .update();

    assert(claimed == 1);
    auto got = repo.query().all()[0];
    assert(got.attempts == 2);                 // +1 then +1
    assert(got.backoff == 880);                // (100+10)*2 = 220, then LEAST(880, 3600)

    c.exec(`DROP TABLE IF EXISTS doc_expr_job`);
}
