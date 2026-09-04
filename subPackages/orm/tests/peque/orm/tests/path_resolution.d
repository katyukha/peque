/** Tests for relation-path resolution robustness.
  *
  * Covers:
  *  - An unknown relation name in a type-free path raises QueryError rather
  *    than tripping an assert (which -release compiles out, letting an empty
  *    column expression reach the server as malformed SQL).
  *  - Path predicates nested inside exists!() are resolved against the outer
  *    model instead of reaching serialisation as raw PathNodes.
  *  - Relation paths deeper than two segments are rejected at compile time via
  *    F!"…" and at runtime in the resolver.
  **/
module peque.orm.tests.path_resolution;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.exception: assertThrown, assertNotThrown, collectExceptionMsg;
private import std.algorithm.searching: canFind;

private import peque.connection: Connection;
private import peque.exception: QueryError;
private import peque.model: model, field, primaryKey, many2one, related;
private import peque.orm;
private import peque.orm.field: PathBuilder;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("pr_companies")
struct PrCompany {
    @primaryKey int    id;
    @field      string name;
}

@model("pr_partners")
struct PrPartner {
    @primaryKey            int                id;
    @field                 string             name;
    @many2one!(PrCompany)  Nullable!int       companyId;
    @related               Nullable!PrCompany company;
}

@model("pr_orders")
struct PrOrder {
    @primaryKey            int                id;
    @field                 string             title;
    @many2one!(PrPartner)  Nullable!int       partnerId;
    @related               Nullable!PrPartner partner;
}

@model("pr_invoices")
struct PrInvoice {
    @primaryKey int    id;
    @field      int    orderId;
    @field      string status;
}

alias PrReg = Registry!(
    Bind!(PrCompany, ModelRepo!PrCompany),
    Bind!(PrPartner, ModelRepo!PrPartner),
    Bind!(PrOrder,   ModelRepo!PrOrder),
    Bind!(PrInvoice, ModelRepo!PrInvoice),
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

// Seeds: two companies, one partner each, three orders, invoices for O1 and O2.
private void setup(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS pr_invoices;");
    c.exec("DROP TABLE IF EXISTS pr_orders;");
    c.exec("DROP TABLE IF EXISTS pr_partners;");
    c.exec("DROP TABLE IF EXISTS pr_companies;");
    c.exec(schemaSQL!PrReg());

    auto companyRepo = Repository!(PrCompany, Connection)(&c);
    auto acmeSeed    = PrCompany(0, "Acme");
    auto globexSeed  = PrCompany(0, "Globex");
    auto acme        = companyRepo.insert(acmeSeed);
    auto globex      = companyRepo.insert(globexSeed);

    auto partnerRepo = Repository!(PrPartner, Connection)(&c);
    auto pAcmeSeed   = PrPartner(0, "P-Acme",   acme.id.nullable);
    auto pGlobexSeed = PrPartner(0, "P-Globex", globex.id.nullable);
    auto pAcme       = partnerRepo.insert(pAcmeSeed);
    auto pGlobex     = partnerRepo.insert(pGlobexSeed);

    auto orderRepo = Repository!(PrOrder, Connection)(&c);
    auto o1Seed = PrOrder(0, "O1", pAcme.id.nullable);
    auto o2Seed = PrOrder(0, "O2", pGlobex.id.nullable);
    auto o3Seed = PrOrder(0, "O3", pAcme.id.nullable);
    auto o1 = orderRepo.insert(o1Seed);
    auto o2 = orderRepo.insert(o2Seed);
    orderRepo.insert(o3Seed);   // O3 deliberately has no invoice

    auto invoiceRepo = Repository!(PrInvoice, Connection)(&c);
    auto i1Seed = PrInvoice(0, o1.id, "open");
    auto i2Seed = PrInvoice(0, o2.id, "open");
    invoiceRepo.insert(i1Seed);
    invoiceRepo.insert(i2Seed);
}


// ---------------------------------------------------------------------------
// Unknown relation name → QueryError (not an assert)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);

    auto repo = Repository!(PrOrder, Connection)(&c);

    // "partnr" is a typo for "partner". This arrives as a runtime string, so it
    // must raise a catchable QueryError; the previous assert was compiled out
    // under -release and let `WHERE ( = $1)` reach the server.
    // The message is asserted so the test cannot pass on a server-side error
    // instead of our own guard — peque wraps PostgreSQL failures in QueryError
    // as well, so the type alone does not distinguish them.
    auto oneLevelMsg = collectExceptionMsg!QueryError(
        repo.query().where(F!"partnr.name"("P-Acme")).all());
    assert(oneLevelMsg.canFind("No @related or @many2one field 'partnr'"),
        "expected the resolver guard, got: " ~ oneLevelMsg);

    // Two-level paths take the same route through _resolveTwoLevel.
    auto twoLevelMsg = collectExceptionMsg!QueryError(
        repo.query().where(F!"partner.compny.name"("Acme")).all());
    assert(twoLevelMsg.canFind("Cannot resolve path 'partner.compny.name'"),
        "expected the resolver guard, got: " ~ twoLevelMsg);

    // The correctly spelled paths still work.
    assertNotThrown(repo.query().where(F!"partner.name"("P-Acme")).all());
    assertNotThrown(repo.query().where(F!"partner.company.name"("Acme")).all());
}


// ---------------------------------------------------------------------------
// Paths deeper than two relation segments are rejected
// ---------------------------------------------------------------------------

unittest {
    // Compile time: F! gates the depth, so the mistake never reaches SQL.
    static assert(__traits(compiles, F!"name"),                       "0 segments");
    static assert(__traits(compiles, F!"partner.name"),               "1 segment");
    static assert(__traits(compiles, F!"partner.company.name"),       "2 segments");
    static assert(!__traits(compiles, F!"partner.company.name.oops"), "3 segments");
    static assert(!__traits(compiles, F!"a.b.c.d.e"),                 "4 segments");
}

unittest {
    auto c = makeConn();
    setup(c);

    auto repo = Repository!(PrOrder, Connection)(&c);

    // PathBuilder can be instantiated directly, bypassing F!'s static assert —
    // the resolver must reject the depth too. Without the guard "a.b.c.d"
    // resolves to `fj1.c.d`, which PostgreSQL parses as schema fj1, table c,
    // column d and rejects — also as a QueryError, so assert on the message to
    // be sure the depth guard is what fired.
    auto deep = PathBuilder!"partner.company.name.oops".init("Acme");
    auto deepMsg = collectExceptionMsg!QueryError(repo.query().where(deep).all());
    assert(deepMsg.canFind("deeper than the two relation segments"),
        "expected the depth guard, got: " ~ deepMsg);
}


// ---------------------------------------------------------------------------
// Path predicates inside exists!() are resolved against the outer model
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);

    auto repo = Repository!(PrOrder, Connection)(&c);

    // Orders having an invoice (correlated on the outer PK) whose partner is
    // P-Acme. The F!"partner.name" term is an outer path nested inside the
    // EXISTS body, so it must be resolved against the OUTER model rather than
    // survive as a PathNode into serialisation.
    auto oneLevel = repo.query().where(
        exists!(PrInvoice)(
            SF!(PrInvoice, "orderId")(F!(PrOrder, "id")) &
            F!"partner.name"("P-Acme")
        )
    ).orderBy("_m.title ASC").all();

    // O1 has an invoice and partner P-Acme; O2 has an invoice but partner
    // P-Globex; O3 has partner P-Acme but no invoice.
    assert(oneLevel.length == 1, "expected only O1");
    assert(oneLevel[0].title == "O1");

    // The same through a two-level path, which allocates a chained filter join
    // inside the EXISTS body and must still land in the outer FROM clause.
    auto twoLevel = repo.query().where(
        exists!(PrInvoice)(
            SF!(PrInvoice, "orderId")(F!(PrOrder, "id")) &
            F!"partner.company.name"("Acme")
        )
    ).orderBy("_m.title ASC").all();

    assert(twoLevel.length == 1);
    assert(twoLevel[0].title == "O1");

    // A non-matching company yields nothing (the join really is applied, rather
    // than the predicate being silently dropped).
    auto none = repo.query().where(
        exists!(PrInvoice)(
            SF!(PrInvoice, "orderId")(F!(PrOrder, "id")) &
            F!"partner.company.name"("Nonexistent")
        )
    ).all();
    assert(none.length == 0);

    // Outer paths combined with the EXISTS from outside still behave.
    auto combined = repo.query().where(
        exists!(PrInvoice)(SF!(PrInvoice, "orderId")(F!(PrOrder, "id"))) &
        F!"partner.company.name"("Globex")
    ).all();
    assert(combined.length == 1);
    assert(combined[0].title == "O2");
}
