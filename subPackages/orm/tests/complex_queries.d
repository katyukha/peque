/** Complex enterprise-like query tests for peque:orm.
  *
  * This file is a design specification for the following upcoming features.
  * Tests are gated with version(PequeOrmComplexQueries) until implemented:
  *
  *  - F!"field"               — type-free main-table field ref (_m.col via camelToSnake)
  *  - F!"rel.field"           — join-path field ref, join added implicitly
  *  - F!"rel.sub.field"       — 2-level implicit join path
  *  - SF!"field"              — subquery field ref (_sq.col), for inside exists!()
  *  - load!("rel")            — explicit join + hydration of @related field
  *  - F!"field".ne(F!"other") — column-to-column inequality
  *  - orderBy(F!"rel.field")  — order by joined column (implicit join)
  *
  * Design principles reflected in these tests:
  *
  *  - Filter joins are IMPLICIT — any F!"rel.field" path in .where()/.orderBy()
  *    automatically adds the required JOIN(s). No .joinOne!() needed to filter.
  *
  *  - Hydration is EXPLICIT — .load!("rel") populates the @related field in the
  *    result struct. Without .load!, the field stays at init even if the table
  *    was joined for filtering purposes.
  *
  *  - select!DTO is fully implicit — joins are inferred from DTO field names via
  *    the join-prefix naming convention (partnerName → partner.name).
  *
  * Domain model:
  *
  *   CqCompany ←── CqPartner ←── CqSaleOrder ──→ CqAddress (invoice)
  *                                            └──→ CqAddress (delivery)
  *                                            └──→ CqInvoice[]
  *   CqCategory (self-referential tree)
  **/
module complex_queries;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.datetime: SysTime, DateTime, UTC;
private import std.conv: to;

private import peque.connection: Connection, Transaction, OnSuccess;
private import peque.model:
    model, field, primaryKey, many2one, related, one2many, autoHydrate;
private import peque.orm;


// ---------------------------------------------------------------------------
// Domain models
// ---------------------------------------------------------------------------

@model("cq_addresses")
struct CqAddress {
    @primaryKey int    id;
    @field      string street;
    @field      string city;
    @field      string country;
}

@model("cq_companies")
struct CqCompany {
    @primaryKey int    id;
    @field      string name;
    @field      int    rate;
}

@model("cq_partners")
struct CqPartner {
    @primaryKey                  int                id;
    @field                       string             name;
    @many2one!(CqCompany)        int                companyId;
    @related("companyId")        Nullable!CqCompany company;
}

@model("cq_sale_orders")
struct CqSaleOrder {
    @primaryKey                      int                 id;
    @field                           string              name;
    @field                           string              status;
    @field                           string              deliveryStatus;
    @field                           SysTime             createdAt;

    @many2one!(CqPartner)            int                 partnerId;
    @related("partnerId")            Nullable!CqPartner  partner;

    @many2one!(CqAddress)            int                 invoiceAddressId;
    @related("invoiceAddressId")     Nullable!CqAddress  invoiceAddress;

    @many2one!(CqAddress)            Nullable!int        deliveryAddressId;
    @related("deliveryAddressId")    Nullable!CqAddress  deliveryAddress;

    @one2many!(CqInvoice, "orderId") CqInvoice[]         invoices;
}

@model("cq_invoices")
struct CqInvoice {
    @primaryKey int    id;
    @field      int    orderId;
    @field      string status;
    @field      double amount;
}

/** Self-referential category tree.
  *
  * Note: @related parent is intentionally absent — a struct cannot contain
  * itself inline (Nullable!CqCategory would be infinite size).  The parent
  * relationship is accessed via parentId FK; children are prefetched via
  * @one2many.  Implicit joins via F!"parentId.*" still work through the FK.
  **/
@model("cq_categories")
struct CqCategory {
    @primaryKey                          int          id;
    @field                               string       name;
    @many2one!(CqCategory)               Nullable!int parentId;
    @one2many!(CqCategory, "parentId")   CqCategory[] children;
}


// ---------------------------------------------------------------------------
// Registry (creation order follows FK dependencies)
// ---------------------------------------------------------------------------

alias CqReg = Registry!(
    Bind!(CqAddress,   ModelRepo!CqAddress),
    Bind!(CqCompany,   ModelRepo!CqCompany),
    Bind!(CqPartner,   ModelRepo!CqPartner),
    Bind!(CqSaleOrder, ModelRepo!CqSaleOrder),
    Bind!(CqInvoice,   ModelRepo!CqInvoice),
    Bind!(CqCategory,  ModelRepo!CqCategory),
);


// ---------------------------------------------------------------------------
// TestFixture — base reference data shared across all tests.
//
// Each test calls TestFixture.create() which drops/recreates all tables and
// inserts the stable reference records (companies, addresses, partners,
// category tree).  Test-specific orders and invoices are created by per-test
// scenario builders defined further below.
// ---------------------------------------------------------------------------

private struct TestFixture {
    Connection conn;

    // Companies
    CqCompany premiumCo;   // rate = 5
    CqCompany basicCo;     // rate = 3

    // Addresses
    CqAddress ukAddr;      // Ukraine / Kyiv
    CqAddress gbAddr;      // GB / London
    CqAddress deAddr;      // DE / Berlin

    // Partners
    CqPartner alphaPart;   // premiumCo
    CqPartner betaPart;    // basicCo

    // Category tree
    CqCategory rootCat;
    CqCategory subCat1;    // parent = rootCat
    CqCategory subCat2;    // parent = rootCat
    CqCategory deepCat;    // parent = subCat1

    // ---------------------------------------------------------------------------
    // Repository helpers
    // ---------------------------------------------------------------------------

    auto orders()     { return Repository!(CqSaleOrder, Connection)(&conn); }
    auto invoices()   { return Repository!(CqInvoice,   Connection)(&conn); }
    auto categories() { return Repository!(CqCategory,  Connection)(&conn); }

    // ---------------------------------------------------------------------------
    // Factory
    // ---------------------------------------------------------------------------

    static TestFixture create() {
        TestFixture f;
        f.conn = Connection(
            dbname:   environment.get("POSTGRES_DB",       "peque-test"),
            user:     environment.get("POSTGRES_USER",     "peque"),
            password: environment.get("POSTGRES_PASSWORD", "peque"),
            host:     environment.get("POSTGRES_HOST",     "localhost"),
            port:     environment.get("POSTGRES_PORT",     "5432"),
        );

        // Recreate schema
        f.conn.exec("DROP TABLE IF EXISTS cq_invoices;");
        f.conn.exec("DROP TABLE IF EXISTS cq_sale_orders;");
        f.conn.exec("DROP TABLE IF EXISTS cq_partners;");
        f.conn.exec("DROP TABLE IF EXISTS cq_companies;");
        f.conn.exec("DROP TABLE IF EXISTS cq_addresses;");
        f.conn.exec("DROP TABLE IF EXISTS cq_categories;");
        f.conn.exec(schemaSQL!CqReg());

        auto comps  = Repository!(CqCompany,  Connection)(&f.conn);
        auto addrs  = Repository!(CqAddress,  Connection)(&f.conn);
        auto parts  = Repository!(CqPartner,  Connection)(&f.conn);
        auto cats   = Repository!(CqCategory, Connection)(&f.conn);

        auto c1 = CqCompany(0, "Premium Ltd", 5);
        auto c2 = CqCompany(0, "Basic GmbH",  3);
        f.premiumCo = comps.insert(c1);
        f.basicCo   = comps.insert(c2);

        auto a1 = CqAddress(0, "Khreshchatyk 1",  "Kyiv",   "Ukraine");
        auto a2 = CqAddress(0, "Baker St 221B",    "London", "GB");
        auto a3 = CqAddress(0, "Unter den Linden", "Berlin", "DE");
        f.ukAddr = addrs.insert(a1);
        f.gbAddr = addrs.insert(a2);
        f.deAddr = addrs.insert(a3);

        auto p1 = CqPartner(0, "Alpha", f.premiumCo.id, Nullable!CqCompany.init);
        auto p2 = CqPartner(0, "Beta",  f.basicCo.id,   Nullable!CqCompany.init);
        f.alphaPart = parts.insert(p1);
        f.betaPart  = parts.insert(p2);

        auto root  = CqCategory(0, "Root",  Nullable!int.init,     []);
        f.rootCat  = cats.insert(root);
        auto sub1  = CqCategory(0, "Sub1",  f.rootCat.id.nullable, []);
        auto sub2  = CqCategory(0, "Sub2",  f.rootCat.id.nullable, []);
        f.subCat1  = cats.insert(sub1);
        f.subCat2  = cats.insert(sub2);
        auto deep  = CqCategory(0, "Deep",  f.subCat1.id.nullable, []);
        f.deepCat  = cats.insert(deep);

        return f;
    }
}


// ---------------------------------------------------------------------------
// Order builder — avoids repeating @related init boilerplate in every test.
// ---------------------------------------------------------------------------

private CqSaleOrder mkOrder(
    string name, string status, string deliveryStatus,
    int partnerId, int invoiceAddrId, Nullable!int deliveryAddrId,
    SysTime createdAt = SysTime(DateTime(2024, 6, 1), UTC()))
{
    CqSaleOrder o;
    o.name             = name;
    o.status           = status;
    o.deliveryStatus   = deliveryStatus;
    o.partnerId        = partnerId;
    o.invoiceAddressId = invoiceAddrId;
    o.deliveryAddressId = deliveryAddrId;
    o.createdAt        = createdAt;
    return o;
}


// ---------------------------------------------------------------------------
// Schema DDL (compiles and runs today — no version gate)
// ---------------------------------------------------------------------------

unittest {
    auto ddl = schemaSQL!CqReg();
    import std.string: indexOf;
    assert(ddl.indexOf("cq_addresses")   >= 0);
    assert(ddl.indexOf("cq_companies")   >= 0);
    assert(ddl.indexOf("cq_partners")    >= 0);
    assert(ddl.indexOf("cq_sale_orders") >= 0);
    assert(ddl.indexOf("cq_invoices")    >= 0);
    assert(ddl.indexOf("cq_categories")  >= 0);
}


// ---------------------------------------------------------------------------
// Scenario data structs + builders
// ---------------------------------------------------------------------------

private struct ComplexFilterScenario {
    CqSaleOrder oMatch;            // ✓ all conditions satisfied
    CqSaleOrder oWrongDelStatus;   // ✗ deliveryStatus = 'confirmed'
    CqSaleOrder oWrongCountry;     // ✗ deliveryAddress.country != Ukraine
    CqSaleOrder oSameAddress;      // ✗ invoiceAddress == deliveryAddress
    CqSaleOrder oLowRate;          // ✗ partner.company.rate = 3
    CqSaleOrder oDraft;            // ✗ status = 'draft'
    CqSaleOrder oNoDelivery;       // ✗ deliveryAddressId IS NULL
}

private ComplexFilterScenario buildComplexFilter(ref TestFixture f) {
    auto repo = f.orders();
    ComplexFilterScenario s;
    auto r0 = mkOrder("CF-MATCH",      "confirmed", "pending",   f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r1 = mkOrder("CF-DEL-STATUS", "confirmed", "confirmed", f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r2 = mkOrder("CF-COUNTRY",    "confirmed", "pending",   f.alphaPart.id, f.gbAddr.id, f.gbAddr.id.nullable);
    auto r3 = mkOrder("CF-SAME-ADDR",  "confirmed", "pending",   f.alphaPart.id, f.ukAddr.id, f.ukAddr.id.nullable);
    auto r4 = mkOrder("CF-LOW-RATE",   "confirmed", "pending",   f.betaPart.id,  f.gbAddr.id, f.ukAddr.id.nullable);
    auto r5 = mkOrder("CF-DRAFT",      "draft",     "pending",   f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r6 = mkOrder("CF-NO-DEL",     "confirmed", "pending",   f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    s.oMatch          = repo.insert(r0);
    s.oWrongDelStatus = repo.insert(r1);
    s.oWrongCountry   = repo.insert(r2);
    s.oSameAddress    = repo.insert(r3);
    s.oLowRate        = repo.insert(r4);
    s.oDraft          = repo.insert(r5);
    s.oNoDelivery     = repo.insert(r6);
    return s;
}

private struct ExistsScenario {
    CqSaleOrder oOpenOnly;           // ✓ has open, no cancelled
    CqSaleOrder oOpenAndCancelled;   // ✗ has open AND cancelled
    CqSaleOrder oPaidOnly;           // ✗ no open invoice
    CqSaleOrder oNoInvoices;         // ✗ no invoices at all
}

private ExistsScenario buildExists(ref TestFixture f) {
    auto orepo = f.orders();
    auto irepo = f.invoices();
    ExistsScenario s;
    auto r0 = mkOrder("EX-OPEN",     "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r1 = mkOrder("EX-MIXED",    "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r2 = mkOrder("EX-PAID",     "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r3 = mkOrder("EX-EMPTY",    "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    s.oOpenOnly         = orepo.insert(r0);
    s.oOpenAndCancelled = orepo.insert(r1);
    s.oPaidOnly         = orepo.insert(r2);
    s.oNoInvoices       = orepo.insert(r3);
    auto i0 = CqInvoice(0, s.oOpenOnly.id,         "open",      500.0);
    auto i1 = CqInvoice(0, s.oOpenAndCancelled.id,  "open",      300.0);
    auto i2 = CqInvoice(0, s.oOpenAndCancelled.id,  "cancelled", 300.0);
    auto i3 = CqInvoice(0, s.oPaidOnly.id,          "paid",      200.0);
    irepo.insert(i0);
    irepo.insert(i1);
    irepo.insert(i2);
    irepo.insert(i3);
    return s;
}

private struct DateRangeScenario {
    CqSaleOrder oJan;    // created 2024-01-15
    CqSaleOrder oFeb;    // created 2024-02-15
    CqSaleOrder oMar;    // created 2024-03-15
}

private DateRangeScenario buildDateRange(ref TestFixture f) {
    auto repo = f.orders();
    DateRangeScenario s;
    auto jan = SysTime(DateTime(2024,  1, 15), UTC());
    auto feb = SysTime(DateTime(2024,  2, 15), UTC());
    auto mar = SysTime(DateTime(2024,  3, 15), UTC());
    auto r0 = mkOrder("DR-JAN", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init, jan);
    auto r1 = mkOrder("DR-FEB", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init, feb);
    auto r2 = mkOrder("DR-MAR", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init, mar);
    s.oJan = repo.insert(r0);
    s.oFeb = repo.insert(r1);
    s.oMar = repo.insert(r2);
    return s;
}

private struct BulkUpdateScenario {
    CqSaleOrder[5] pending;   // status = 'pending', old
    CqSaleOrder[3] recent;    // status = 'pending', recent
    CqSaleOrder[2] confirmed; // status = 'confirmed', old
}

private BulkUpdateScenario buildBulkUpdate(ref TestFixture f) {
    auto repo = f.orders();
    BulkUpdateScenario s;
    auto old    = SysTime(DateTime(2023,  1,  1), UTC());
    auto recent = SysTime(DateTime(2024,  6,  1), UTC());
    foreach (i; 0 .. 5) {
        auto r = mkOrder("BU-OLD-" ~ to!string(i), "pending", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init, old);
        s.pending[i] = repo.insert(r);
    }
    foreach (i; 0 .. 3) {
        auto r = mkOrder("BU-NEW-" ~ to!string(i), "pending", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init, recent);
        s.recent[i] = repo.insert(r);
    }
    foreach (i; 0 .. 2) {
        auto r = mkOrder("BU-CONF-" ~ to!string(i), "confirmed", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init, old);
        s.confirmed[i] = repo.insert(r);
    }
    return s;
}

private struct PaginationScenario {
    CqSaleOrder[12] confirmed;
    CqSaleOrder[3]  drafts;
}

private PaginationScenario buildPagination(ref TestFixture f) {
    auto repo = f.orders();
    PaginationScenario s;
    foreach (i; 0 .. 12) {
        auto r = mkOrder("PG-CONF-" ~ to!string(i), "confirmed", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
        s.confirmed[i] = repo.insert(r);
    }
    foreach (i; 0 .. 3) {
        auto r = mkOrder("PG-DRAFT-" ~ to!string(i), "draft", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
        s.drafts[i] = repo.insert(r);
    }
    return s;
}

private struct PrefetchScenario {
    CqSaleOrder order;
    CqInvoice   invOpen;
    CqInvoice   invPaid;
}

private PrefetchScenario buildPrefetch(ref TestFixture f) {
    auto orepo = f.orders();
    auto irepo = f.invoices();
    PrefetchScenario s;
    auto r = mkOrder("PF-ORDER", "confirmed", "pending",
                     f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    s.order = orepo.insert(r);
    auto i0 = CqInvoice(0, s.order.id, "open", 250.0);
    auto i1 = CqInvoice(0, s.order.id, "paid", 750.0);
    s.invOpen = irepo.insert(i0);
    s.invPaid = irepo.insert(i1);
    return s;
}


// ---------------------------------------------------------------------------
// 1. Multi-join complex filter — implicit filter joins, explicit load! only
//    for @related fields accessed in assertions.
// ---------------------------------------------------------------------------

unittest {
    auto f  = TestFixture.create();
    auto s  = buildComplexFilter(f);

    auto results = f.orders().query()
        .load!("invoiceAddress")
        .load!("deliveryAddress")
        .where(F!"status"("confirmed"))
        .where(F!"deliveryStatus".ne("confirmed"))
        .where(F!"deliveryAddress.country"("Ukraine"))
        .where(~F!"invoiceAddressId".isNull)
        .where(F!"invoiceAddressId".ne(F!"deliveryAddressId"))
        .where(F!"partner.company.rate"(5))
        .all();

    assert(results.length == 1);
    assert(results[0].id == s.oMatch.id);
    assert(!results[0].invoiceAddress.isNull);
    assert(!results[0].deliveryAddress.isNull);
    assert(results[0].deliveryAddress.get.country == "Ukraine");
    assert(results[0].partner.isNull);  // joined for filtering, not loaded
}


// ---------------------------------------------------------------------------
// 2. EXISTS / NOT EXISTS — orders with an open invoice and no cancelled one.
// ---------------------------------------------------------------------------

unittest {
    auto f = TestFixture.create();
    auto s = buildExists(f);

    auto results = f.orders().query()
        .where(exists!(CqInvoice)(
            SF!"orderId"(F!"id") &
            SF!"status"("open")
        ))
        .where(~exists!(CqInvoice)(
            SF!"orderId"(F!"id") &
            SF!"status"("cancelled")
        ))
        .all();

    assert(results.length == 1);
    assert(results[0].id == s.oOpenOnly.id);
}


// ---------------------------------------------------------------------------
// 3. Compound predicate composition (OR / AND / NOT / comparisons)
//    rate >= 4 AND (confirmed OR done) AND delivery address is set.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();

    auto r0 = mkOrder("CP-CONF-PREM", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r1 = mkOrder("CP-DONE-PREM", "done",      "pending", f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r2 = mkOrder("CP-DRAFT",     "draft",     "pending", f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    auto r3 = mkOrder("CP-LOW-RATE",  "confirmed", "pending", f.betaPart.id,  f.gbAddr.id, f.ukAddr.id.nullable);
    auto r4 = mkOrder("CP-NO-DEL",    "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto o0 = repo.insert(r0);
    auto o1 = repo.insert(r1);
    repo.insert(r2);
    repo.insert(r3);
    repo.insert(r4);

    auto results = f.orders().query()
        .where(
            F!"partner.company.rate".gte(4) &
            (F!"status"("confirmed") | F!"status"("done")) &
            ~F!"deliveryAddressId".isNull
        )
        .all();

    assert(results.length == 2);
    import std.algorithm: map, canFind;
    auto ids = results.map!(r => r.id);
    assert(ids.canFind(o0.id));
    assert(ids.canFind(o1.id));
}


// ---------------------------------------------------------------------------
// 4. whereIn — filter by a set of values.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();

    auto r0 = mkOrder("WI-CONF", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r1 = mkOrder("WI-DONE", "done",      "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r2 = mkOrder("WI-CANC", "cancelled", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r3 = mkOrder("WI-DRFT", "draft",     "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto o0 = repo.insert(r0);
    auto o1 = repo.insert(r1);
    repo.insert(r2);
    repo.insert(r3);

    auto results = f.orders().query()
        .where(F!"status".contains(["confirmed", "done"]))
        .all();

    assert(results.length == 2);
    import std.algorithm: map, canFind;
    auto ids = results.map!(r => r.id);
    assert(ids.canFind(o0.id));
    assert(ids.canFind(o1.id));
}


// ---------------------------------------------------------------------------
// 5. Date range filter — orders created within a specific period.
// ---------------------------------------------------------------------------

unittest {
    auto f = TestFixture.create();
    auto s = buildDateRange(f);

    immutable periodStart = SysTime(DateTime(2024,  2,  1), UTC());
    immutable periodEnd   = SysTime(DateTime(2024,  3,  1), UTC());

    // February only (gte start, lt end)
    auto results = f.orders().query()
        .where(F!"createdAt".gte(periodStart))
        .where(F!"createdAt".lt(periodEnd))
        .all();

    assert(results.length == 1);
    assert(results[0].id == s.oFeb.id);
}


// ---------------------------------------------------------------------------
// 6. Self-referential model — category tree.
//    Queries on self-referential FK; children prefetched via @one2many.
//    Note: load!("parent") is not possible — a struct cannot contain itself
//    inline.  Parent is accessed via parentId; implicit joins via F!"rel.field"
//    still work through the FK column for filtering.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto cats = f.categories();

    // Direct children of root — filter by FK
    auto directChildren = cats.query()
        .where(F!"parentId"(f.rootCat.id))
        .all();

    assert(directChildren.length == 2);
    import std.algorithm: map, canFind;
    auto childIds = directChildren.map!(c => c.id);
    assert(childIds.canFind(f.subCat1.id));
    assert(childIds.canFind(f.subCat2.id));

    // Root with its children prefetched
    auto roots = cats.query()
        .prefetch!("children")
        .where(F!"parentId".isNull)
        .all();

    assert(roots.length == 1);
    assert(roots[0].id == f.rootCat.id);
    assert(roots[0].children.length == 2);

    // Grandchildren — implicit 2-level join: deepCat.parentId → subCat, subCat.parentId = rootCat.id
    auto grandchildren = cats.query()
        .where(F!"parentId.parentId"(f.rootCat.id))
        .all();

    assert(grandchildren.length == 1);
    assert(grandchildren[0].id == f.deepCat.id);
}


// ---------------------------------------------------------------------------
// 7. Reusable base query composition — a shared base filter reused across
//    count, page fetch, and a further-narrowed sub-query.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto s    = buildPagination(f);

    // Base query shared by all derived queries below
    auto base = f.orders().query()
        .where(F!"status"("confirmed"))
        .where(F!"partner.company.rate".gte(3));

    assert(base.count() == 12);

    // Narrow further without modifying base
    auto ukOnly = base
        .where(F!"deliveryAddress.country"("Ukraine"))
        .count();
    assert(ukOnly == 0);  // no delivery addresses set in pagination scenario

    // Page 2 (5 per page)
    auto page2 = base.orderBy("id ASC").limit(5).offset(5).all();
    assert(page2.length == 5);

    // Base query still unmodified
    assert(base.count() == 12);
}


// ---------------------------------------------------------------------------
// 8. load! + prefetch! combined — partner hydrated via JOIN, invoices via
//    post-query SELECT.  Tests that both mechanisms coexist on the same query.
// ---------------------------------------------------------------------------

unittest {
    auto f = TestFixture.create();
    auto s = buildPrefetch(f);

    auto results = f.orders().query()
        .load!("partner")
        .prefetch!("invoices")
        .where(F!"id"(s.order.id))
        .all();

    assert(results.length == 1);
    assert(!results[0].partner.isNull);
    assert(results[0].partner.get.name == "Alpha");
    assert(results[0].invoices.length == 2);

    import std.algorithm: map, canFind;
    auto statuses = results[0].invoices.map!(i => i.status);
    assert(statuses.canFind("open"));
    assert(statuses.canFind("paid"));
}


// ---------------------------------------------------------------------------
// 9. Bulk update — cancel all old pending orders in one UPDATE statement.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto s    = buildBulkUpdate(f);
    auto repo = f.orders();

    immutable cutoff = SysTime(DateTime(2024, 1, 1), UTC());

    auto affected = repo.query()
        .where(F!"status"("pending"))
        .where(F!"createdAt".lt(cutoff))
        .set!"status"("cancelled")
        .update();

    assert(affected == 5);  // only the 5 old pending orders

    // Verify: recent pending and confirmed orders are untouched
    assert(repo.query().where(F!"status"("pending")).count()   == 3);
    assert(repo.query().where(F!"status"("confirmed")).count() == 2);
    assert(repo.query().where(F!"status"("cancelled")).count() == 5);
}


// ---------------------------------------------------------------------------
// 10. Partial update of a single record — update specific fields by PK.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();
    auto r    = mkOrder("PU-ORDER", "confirmed", "pending",
                        f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto o    = repo.insert(r);

    repo.query()
        .where(F!"id"(o.id))
        .set!"status"("invoiced")
        .set!"deliveryStatus"("dispatched")
        .update();

    auto updated = repo.findById(o.id).get;
    assert(updated.status         == "invoiced");
    assert(updated.deliveryStatus == "dispatched");
    assert(updated.name           == "PU-ORDER");  // untouched field unchanged
}


// ---------------------------------------------------------------------------
// 11. select!DTO — flat projection across three joins, fully implicit.
//     No explicit .load!() — DTO field names drive the join list.
// ---------------------------------------------------------------------------

@autoHydrate
struct OrderSummaryDTO {
    int    id;
    string name;
    string status;
    string partnerName;              // partner.name
    string invoiceAddressCity;       // invoiceAddress.city
    string deliveryAddressCountry;   // deliveryAddress.country
}

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();
    auto r    = mkOrder("DTO-ORDER", "confirmed", "pending",
                        f.alphaPart.id, f.gbAddr.id, f.ukAddr.id.nullable);
    repo.insert(r);

    auto dtos = repo.query()
        .where(F!"name"("DTO-ORDER"))
        .select!OrderSummaryDTO();

    assert(dtos.length == 1);
    assert(dtos[0].name                  == "DTO-ORDER");
    assert(dtos[0].partnerName           == "Alpha");
    assert(dtos[0].invoiceAddressCity    == "London");
    assert(dtos[0].deliveryAddressCountry == "Ukraine");
}


// ---------------------------------------------------------------------------
// 12. orderBy joined field — implicit join added for ORDER BY path.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();

    // Two orders with different partners: Alpha (Premium) and Beta (Basic)
    auto r0 = mkOrder("OJ-BETA",  "confirmed", "pending", f.betaPart.id,  f.gbAddr.id, Nullable!int.init);
    auto r1 = mkOrder("OJ-ALPHA", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    repo.insert(r0);
    repo.insert(r1);

    // Sort by partner name ascending — implicit join on partner
    auto results = f.orders().query()
        .where(F!"status"("confirmed"))
        .orderBy(F!"partner.name")
        .all();

    assert(results.length == 2);
    assert(results[0].partnerId == f.alphaPart.id);  // Alpha < Beta
    assert(results[1].partnerId == f.betaPart.id);
}


// ---------------------------------------------------------------------------
// 13. Pagination + count — list endpoint pattern.
// ---------------------------------------------------------------------------

unittest {
    auto f = TestFixture.create();
    auto s = buildPagination(f);

    auto base = f.orders().query().where(F!"status"("confirmed"));

    assert(base.count() == 12);

    auto page1 = base.orderBy("id ASC").limit(5).offset(0).all();
    auto page2 = base.orderBy("id ASC").limit(5).offset(5).all();
    auto page3 = base.orderBy("id ASC").limit(5).offset(10).all();

    assert(page1.length == 5);
    assert(page2.length == 5);
    assert(page3.length == 2);  // last page: only 2 remain
}


// ---------------------------------------------------------------------------
// 14. Aggregate reporting — total invoice amount per order.
//
//     Native aggregation (GROUP BY / SUM / COUNT) is not yet supported by
//     the ORM.  This test documents the current workaround via whereRaw and
//     serves as a placeholder for the feature gap.
// ---------------------------------------------------------------------------

@autoHydrate
struct OrderTotalsDTO {
    int    id;
    string name;
    long   invoiceCount;
    double totalAmount;
}

unittest {
    auto f    = TestFixture.create();
    auto orepo = f.orders();
    auto irepo = f.invoices();

    auto r = mkOrder("AGG-ORDER", "confirmed", "pending",
                     f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto o = orepo.insert(r);
    auto i0 = CqInvoice(0, o.id, "open", 300.0);
    auto i1 = CqInvoice(0, o.id, "paid", 700.0);
    irepo.insert(i0);
    irepo.insert(i1);

    // Workaround: raw SQL until native aggregation is supported.
    // Desired future API (not yet implemented):
    //
    //   orepo.query()
    //       .annotate!"invoiceCount"("COUNT(inv.id)")
    //       .annotate!"totalAmount"("SUM(inv.amount)")
    //       .joinMany!("invoices", "inv")
    //       .groupBy(F!"id")
    //       .where(F!"id"(o.id))
    //       .select!OrderTotalsDTO();

    auto result = f.conn.execParams(
        "SELECT o.id, o.name, COUNT(i.id) AS invoice_count, COALESCE(SUM(i.amount), 0) AS total_amount" ~
        " FROM cq_sale_orders o" ~
        " LEFT JOIN cq_invoices i ON i.order_id = o.id" ~
        " WHERE o.id = $1" ~
        " GROUP BY o.id, o.name",
        o.id
    );
    auto dto = result.getRow(0).as!OrderTotalsDTO;
    assert(dto.invoiceCount == 2);
    assert(dto.totalAmount  == 1000.0);
}


// ---------------------------------------------------------------------------
// 15. Transaction-scoped queries — Repository works identically inside a
//     transaction.  Demonstrates commit (changes visible after) and
//     OnSuccess.rollback dry-run (changes invisible after).
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();

    // --- 15a. Commit: changes are visible after the transaction. ---
    CqSaleOrder committed;
    f.conn.transaction((ref tx) {
        auto txRepo = Repository!(CqSaleOrder, Transaction)(&tx);
        auto r = mkOrder("TX-COMMIT", "confirmed", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
        committed = txRepo.insert(r);
    });

    // Visible outside the transaction
    auto found = repo.findById(committed.id);
    assert(!found.isNull);
    assert(found.get.name == "TX-COMMIT");

    // --- 15b. Rollback: OnSuccess.rollback leaves no trace. ---
    int dryRunId;
    f.conn.transaction!(OnSuccess.rollback)((ref tx) {
        auto txRepo = Repository!(CqSaleOrder, Transaction)(&tx);
        auto r = mkOrder("TX-ROLLBACK", "confirmed", "pending",
                         f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
        auto inserted = txRepo.insert(r);
        dryRunId = inserted.id;

        // Visible *inside* the transaction
        auto inside = txRepo.findById(dryRunId);
        assert(!inside.isNull);
        assert(inside.get.name == "TX-ROLLBACK");
    });

    // Not visible after rollback
    assert(repo.findById(dryRunId).isNull);

    // --- 15c. Exception rollback: explicit throw reverts all changes. ---
    int thrownId;
    try {
        f.conn.transaction((ref tx) {
            auto txRepo = Repository!(CqSaleOrder, Transaction)(&tx);
            auto r = mkOrder("TX-THROW", "confirmed", "pending",
                             f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
            thrownId = txRepo.insert(r).id;
            throw new Exception("deliberate rollback");
        });
    } catch (Exception) {}

    assert(repo.findById(thrownId).isNull);
}


// ---------------------------------------------------------------------------
// 16. LIKE / full-text search — prefix match, substring match, and LIKE on a
//     joined field path.
// ---------------------------------------------------------------------------

unittest {
    auto f    = TestFixture.create();
    auto repo = f.orders();

    // Insert several orders whose names differ by prefix / substring
    auto r0 = mkOrder("ALPHA-001",  "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r1 = mkOrder("ALPHA-002",  "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    auto r2 = mkOrder("BETA-001",   "confirmed", "pending", f.betaPart.id,  f.gbAddr.id, Nullable!int.init);
    auto r3 = mkOrder("GAMMA-ALPH", "confirmed", "pending", f.alphaPart.id, f.gbAddr.id, Nullable!int.init);
    repo.insert(r0);
    repo.insert(r1);
    repo.insert(r2);
    repo.insert(r3);

    import std.algorithm: map, canFind;

    // Prefix search — only orders starting with "ALPHA"
    auto prefixResults = repo.query()
        .where(F!"name".like("ALPHA%"))
        .all();
    assert(prefixResults.length == 2);
    auto prefixNames = prefixResults.map!(o => o.name);
    assert(prefixNames.canFind("ALPHA-001"));
    assert(prefixNames.canFind("ALPHA-002"));

    // Substring search — all orders that contain "ALPH"
    auto subResults = repo.query()
        .where(F!"name".like("%ALPH%"))
        .all();
    assert(subResults.length == 3);  // ALPHA-001, ALPHA-002, GAMMA-ALPH
    auto subNames = subResults.map!(o => o.name);
    assert(subNames.canFind("GAMMA-ALPH"));

    // LIKE on a joined field — orders whose partner name starts with "Alpha"
    // (implicit join on partner; tests that like() works on a join path)
    auto joinedResults = repo.query()
        .where(F!"partner.name".like("Alpha%"))
        .all();
    assert(joinedResults.length >= 3);  // all orders with partner Alpha
    foreach (o; joinedResults)
        assert(o.partnerId == f.alphaPart.id);
}
