/** Integration tests for QuerySet.joinOne!, prefetch!, and select!DTO.
  *
  * Covers:
  *  - joinOne! populates a @related Nullable!T field via LEFT JOIN
  *  - joinOne! with no matching FK → Nullable.init
  *  - prefetch! for @one2many fills the array field after main query
  *  - prefetch! for @many2many fills the array field via junction table
  *  - select!DTO projects main + joined columns into a lightweight DTO
  **/
module peque.orm.tests.join;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related,
    one2many, many2many;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("jt_partners")
struct JtPartner {
    @primaryKey int    id;
    @field      string name;
}

@model("jt_invoices")
struct JtInvoice {
    @primaryKey             int                id;
    @field                  string             name;
    @many2one!(JtPartner)   Nullable!int       partnerId;
    @related                Nullable!JtPartner partner;
}

// Partner with one2many
@model("jt_partners2")
struct JtPartner2 {
    @primaryKey                              int          id;
    @field                                   string       name;
    @one2many!(JtInvoice2, "partnerId")      JtInvoice2[] invoices;
}

@model("jt_invoices2")
struct JtInvoice2 {
    @primaryKey             int    id;
    @field                  string name;
    @many2one!(JtPartner2)  int    partnerId;
}

// Models for many2many
@model("jt_tags")
struct JtTag {
    @primaryKey int    id;
    @field      string name;
}

@model("jt_companies")
struct JtCompany {
    @primaryKey                                                      int      id;
    @field                                                           string   name;
    @many2many!(JtTag, "jt_company_tag_rel", "company_id", "tag_id") JtTag[]  tags;
}


// ---------------------------------------------------------------------------
// Registry / schema helpers
// ---------------------------------------------------------------------------

alias JtReg = Registry!(
    Bind!(JtPartner,  ModelRepo!JtPartner),
    Bind!(JtInvoice,  ModelRepo!JtInvoice),
    Bind!(JtPartner2, ModelRepo!JtPartner2),
    Bind!(JtInvoice2, ModelRepo!JtInvoice2),
    Bind!(JtTag,      ModelRepo!JtTag),
    Bind!(JtCompany,  ModelRepo!JtCompany),
);


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

private void setupJoinTables(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS jt_invoices;
        DROP TABLE IF EXISTS jt_partners;
        CREATE TABLE jt_partners (
            id   serial PRIMARY KEY,
            name varchar(80) NOT NULL
        );
        CREATE TABLE jt_invoices (
            id         serial PRIMARY KEY,
            name       varchar(80) NOT NULL,
            partner_id int REFERENCES jt_partners(id)
        );
        INSERT INTO jt_partners (name) VALUES ('Acme Corp'), ('Globex');
        INSERT INTO jt_invoices (name, partner_id)
            SELECT 'INV-001', id FROM jt_partners WHERE name = 'Acme Corp';
        INSERT INTO jt_invoices (name, partner_id)
            SELECT 'INV-002', id FROM jt_partners WHERE name = 'Acme Corp';
        INSERT INTO jt_invoices (name, partner_id)
            SELECT 'INV-003', id FROM jt_partners WHERE name = 'Globex';
        -- One invoice with NULL partner_id
        INSERT INTO jt_invoices (name, partner_id) VALUES ('INV-NULL', NULL);
    `);
}

private void setupO2MTables(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS jt_invoices2;
        DROP TABLE IF EXISTS jt_partners2;
        CREATE TABLE jt_partners2 (
            id   serial PRIMARY KEY,
            name varchar(80) NOT NULL
        );
        CREATE TABLE jt_invoices2 (
            id         serial PRIMARY KEY,
            name       varchar(80) NOT NULL,
            partner_id int REFERENCES jt_partners2(id)
        );
        INSERT INTO jt_partners2 (name) VALUES ('Alpha Co'), ('Beta Co');
        INSERT INTO jt_invoices2 (name, partner_id)
            SELECT 'A-1', id FROM jt_partners2 WHERE name = 'Alpha Co';
        INSERT INTO jt_invoices2 (name, partner_id)
            SELECT 'A-2', id FROM jt_partners2 WHERE name = 'Alpha Co';
        INSERT INTO jt_invoices2 (name, partner_id)
            SELECT 'B-1', id FROM jt_partners2 WHERE name = 'Beta Co';
    `);
}

private void setupM2MTables(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS jt_company_tag_rel;
        DROP TABLE IF EXISTS jt_companies;
        DROP TABLE IF EXISTS jt_tags;
        CREATE TABLE jt_tags (
            id   serial PRIMARY KEY,
            name varchar(40) NOT NULL
        );
        CREATE TABLE jt_companies (
            id   serial PRIMARY KEY,
            name varchar(80) NOT NULL
        );
        CREATE TABLE jt_company_tag_rel (
            company_id int REFERENCES jt_companies(id),
            tag_id     int REFERENCES jt_tags(id)
        );
        INSERT INTO jt_tags (name) VALUES ('vip'), ('partner'), ('supplier');
        INSERT INTO jt_companies (name) VALUES ('Alpha Inc'), ('Beta LLC');
        -- Alpha Inc: vip + partner
        INSERT INTO jt_company_tag_rel (company_id, tag_id)
            SELECT c.id, t.id FROM jt_companies c, jt_tags t
            WHERE c.name = 'Alpha Inc' AND t.name IN ('vip', 'partner');
        -- Beta LLC: supplier
        INSERT INTO jt_company_tag_rel (company_id, tag_id)
            SELECT c.id, t.id FROM jt_companies c, jt_tags t
            WHERE c.name = 'Beta LLC' AND t.name = 'supplier';
    `);
}


// ---------------------------------------------------------------------------
// joinOne! — basic: partner is populated
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupJoinTables(c);
    auto repo = Repository!(JtInvoice, Connection)(&c);

    auto invoices = repo.query()
                        .joinOne!("partner")
                        .whereRaw("_m.name = $1", "INV-001")
                        .all();

    assert(invoices.length == 1);
    assert(!invoices[0].partner.isNull);
    assert(invoices[0].partner.get.name == "Acme Corp");
    assert(!invoices[0].partnerId.isNull);
    assert(invoices[0].partnerId.get == invoices[0].partner.get.id);
}


// ---------------------------------------------------------------------------
// joinOne! — NULL FK → Nullable.init
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupJoinTables(c);
    auto repo = Repository!(JtInvoice, Connection)(&c);

    auto invoices = repo.query()
                        .joinOne!("partner")
                        .whereRaw("_m.name = $1", "INV-NULL")
                        .all();

    assert(invoices.length == 1);
    assert(invoices[0].partner.isNull);
}


// ---------------------------------------------------------------------------
// joinOne! — all invoices: mixed null / non-null
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupJoinTables(c);
    auto repo = Repository!(JtInvoice, Connection)(&c);

    auto invoices = repo.query().joinOne!("partner").all();
    assert(invoices.length == 4);

    int withPartner = 0;
    int nullPartner = 0;
    foreach (inv; invoices) {
        if (inv.partner.isNull) nullPartner++;
        else withPartner++;
    }
    assert(withPartner == 3);
    assert(nullPartner == 1);
}


// ---------------------------------------------------------------------------
// prefetch! @one2many
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupO2MTables(c);
    auto repo = Repository!(JtPartner2, Connection)(&c);

    auto partners = repo.query()
                        .orderBy("name ASC")
                        .prefetch!("invoices")
                        .all();

    assert(partners.length == 2);
    // Alpha Co → 2 invoices
    assert(partners[0].name == "Alpha Co");
    assert(partners[0].invoices.length == 2);
    // Beta Co → 1 invoice
    assert(partners[1].name == "Beta Co");
    assert(partners[1].invoices.length == 1);
    assert(partners[1].invoices[0].name == "B-1");
}


// ---------------------------------------------------------------------------
// prefetch! @many2many
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupM2MTables(c);
    auto repo = Repository!(JtCompany, Connection)(&c);

    auto companies = repo.query()
                         .orderBy("name ASC")
                         .prefetch!("tags")
                         .all();

    assert(companies.length == 2);
    // Alpha Inc: 2 tags (vip, partner)
    assert(companies[0].name == "Alpha Inc");
    assert(companies[0].tags.length == 2);
    // Beta LLC: 1 tag (supplier)
    assert(companies[1].name == "Beta LLC");
    assert(companies[1].tags.length == 1);
    assert(companies[1].tags[0].name == "supplier");
}


// ---------------------------------------------------------------------------
// select!DTO — project main + join columns
// ---------------------------------------------------------------------------

import peque.model: autoHydrate;

@autoHydrate
struct InvoicePartnerDTO {
    int    id;
    string name;
    string partnerName;   // join alias: partner_name → j0.name AS partner_name
}

unittest {
    auto c = makeConn();
    setupJoinTables(c);
    auto repo = Repository!(JtInvoice, Connection)(&c);

    auto dtos = repo.query()
                    .joinOne!("partner")
                    .whereRaw("_m.name != $1", "INV-NULL")
                    .orderBy("_m.name ASC")
                    .select!InvoicePartnerDTO();

    assert(dtos.length == 3);
    assert(dtos[0].name == "INV-001");
    assert(dtos[0].partnerName == "Acme Corp");
    assert(dtos[1].name == "INV-002");
    assert(dtos[1].partnerName == "Acme Corp");
    assert(dtos[2].name == "INV-003");
    assert(dtos[2].partnerName == "Globex");
}
