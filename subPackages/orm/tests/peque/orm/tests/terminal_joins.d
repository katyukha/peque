/** Integration tests: QuerySet terminals must honor join state exactly like all().
  *
  * Covers:
  *  - count() / exists() / aggregate!() on a QuerySet with load! + path predicate
  *    (predicates resolve to the hydration-join alias, so the terminal must emit
  *    the same LEFT JOINs as all())
  *  - the same terminals with a pure filter join (no load!)
  *  - asSubquery!() keeps orderBy + limit ("top N" subqueries)
  *  - delete_() / update() keep LEFT JOIN semantics for path predicates
  *    (F!"rel.field".isNull must match rows with NULL FK, exactly as in all())
  *  - delete_() / update() on a QuerySet with load! + path predicate
  **/
module peque.orm.tests.terminal_joins;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related;
private import peque.orm;
private import peque.orm.field: F;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("tj_partners")
struct TjPartner {
    @primaryKey int    id;
    @field      string name;
}

@model("tj_invoices")
struct TjInvoice {
    @primaryKey             int                id;
    @field                  string             name;
    @field                  double             amount;
    @many2one!(TjPartner)   Nullable!int       partnerId;
    @related                Nullable!TjPartner partner;
}


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

// Fixture: Acme Corp (INV-001 10.0, INV-002 20.0), Globex (INV-003 30.0),
// one orphan invoice with NULL partner (INV-NULL 40.0).
private void setup(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS tj_invoices;
        DROP TABLE IF EXISTS tj_partners;
        CREATE TABLE tj_partners (
            id   serial PRIMARY KEY,
            name varchar(80) NOT NULL
        );
        CREATE TABLE tj_invoices (
            id         serial PRIMARY KEY,
            name       varchar(80) NOT NULL,
            amount     double precision NOT NULL,
            partner_id int REFERENCES tj_partners(id)
        );
        INSERT INTO tj_partners (name) VALUES ('Acme Corp'), ('Globex');
        INSERT INTO tj_invoices (name, amount, partner_id)
            SELECT 'INV-001', 10.0, id FROM tj_partners WHERE name = 'Acme Corp';
        INSERT INTO tj_invoices (name, amount, partner_id)
            SELECT 'INV-002', 20.0, id FROM tj_partners WHERE name = 'Acme Corp';
        INSERT INTO tj_invoices (name, amount, partner_id)
            SELECT 'INV-003', 30.0, id FROM tj_partners WHERE name = 'Globex';
        INSERT INTO tj_invoices (name, amount, partner_id) VALUES ('INV-NULL', 40.0, NULL);
    `);
}


// ---------------------------------------------------------------------------
// count / exists / aggregate on a QuerySet carrying load! + path predicate
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    auto qs = repo.query()
        .load!"partner"
        .where(F!"partner.name"("Acme Corp"));

    // all() is the reference behavior
    assert(qs.all().length == 2);

    // every other terminal must see the same row set
    assert(qs.count() == 2);
    assert(qs.exists());

    auto total = qs.aggregate!(F!(TjInvoice, "amount").sum);
    assert(!total.isNull);
    assert(total.get == 30.0);  // 10 + 20

    // and the empty-match case must agree too
    auto none = repo.query()
        .load!"partner"
        .where(F!"partner.name"("No Such Partner"));
    assert(none.all().length == 0);
    assert(none.count() == 0);
    assert(!none.exists());
    assert(none.aggregate!(F!(TjInvoice, "amount").sum).isNull);
}


// ---------------------------------------------------------------------------
// count / exists / aggregate with a pure filter join (no load!)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    auto qs = repo.query().where(F!"partner.name"("Acme Corp"));
    assert(qs.all().length == 2);
    assert(qs.count() == 2);
    assert(qs.exists());
    assert(qs.aggregate!(F!(TjInvoice, "amount").sum).get == 30.0);
}


// ---------------------------------------------------------------------------
// asSubquery!() must keep orderBy + limit ("top N by amount")
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    // ids of the two most expensive invoices: INV-NULL (40), INV-003 (30)
    auto sub = repo.query()
        .orderBy(F!"amount".desc)
        .limit(2)
        .asSubquery!"id"();

    auto top = repo.query()
        .where(F!(TjInvoice, "id").inSubquery(sub))
        .orderBy(F!"amount".desc)
        .all();

    assert(top.length == 2);
    assert(top[0].name == "INV-NULL" && top[0].amount == 40.0);
    assert(top[1].name == "INV-003"  && top[1].amount == 30.0);

    // subquery carrying load! + path predicate must emit its joins as well
    auto acmeSub = repo.query()
        .load!"partner"
        .where(F!"partner.name"("Acme Corp"))
        .asSubquery!"id"();
    auto acme = repo.query()
        .where(F!(TjInvoice, "id").inSubquery(acmeSub))
        .all();
    assert(acme.length == 2);
}


// ---------------------------------------------------------------------------
// delete_() must keep LEFT JOIN semantics: rel-path isNull matches NULL FK rows
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    // Reference: all() matches the orphan invoice via LEFT JOIN
    auto matched = repo.query().where(F!"partner.name".isNull).all();
    assert(matched.length == 1);
    assert(matched[0].name == "INV-NULL");

    // delete_() must remove exactly the same row set
    auto deleted = repo.query().where(F!"partner.name".isNull).delete_();
    assert(deleted == 1);
    assert(repo.query().count() == 3);
    assert(repo.query().where(F!"partner.name".isNull).count() == 0);
}


// ---------------------------------------------------------------------------
// update() must keep LEFT JOIN semantics for rel-path predicates
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    auto updated = repo.query()
        .where(F!"partner.name".isNull)
        .set!"name"("ORPHAN")
        .update();
    assert(updated == 1);

    auto orphan = repo.query().where!"name"("ORPHAN").first();
    assert(!orphan.isNull);
    assert(orphan.get.amount == 40.0);
    assert(orphan.get.partnerId.isNull);

    // non-null path predicate keeps working (matched rows only)
    auto renamed = repo.query()
        .where(F!"partner.name"("Globex"))
        .set!"name"("GLOBEX-INV")
        .update();
    assert(renamed == 1);
}


// ---------------------------------------------------------------------------
// delete_() / update() on a QuerySet carrying load! + path predicate
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setup(c);
    auto repo = Repository!(TjInvoice, Connection)(&c);

    auto updated = repo.query()
        .load!"partner"
        .where(F!"partner.name"("Acme Corp"))
        .set!"amount"(0.0)
        .update();
    assert(updated == 2);
    assert(repo.query().where!"amount"(0.0).count() == 2);

    auto deleted = repo.query()
        .load!"partner"
        .where(F!"partner.name"("Globex"))
        .delete_();
    assert(deleted == 1);
    assert(repo.query().count() == 3);
}
