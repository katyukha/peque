/** Integration + CTFE tests for the ORM-correctness fixes.
  *
  * Covers:
  *  #1 — @field("col") override on the @primaryKey is honored by ormPkColName
  *       (and end-to-end CRUD stays internally consistent).
  *  #2 — where!"field"(null Nullable) becomes `IS NULL` (and .ne(null) becomes
  *       `IS NOT NULL`) instead of the never-matching `col = NULL`.
  *  #3 — @many2many prefetch qualifies target columns (junction sharing an `id`
  *       column is no longer ambiguous) and aliases the self-key (self-
  *       referential m2m stitches correctly).
  *  #4 — set!"field" twice is last-write-wins (no "multiple assignments to same
  *       column"); CRUD update() on a zero-non-PK-column model is a compile
  *       error, mirroring upsert().
  *  #5 — select!DTO binds a column to the relation with the LONGEST matching
  *       prefix, so partner_company_name resolves against partnerCompany, not
  *       partner.
  **/
module peque.orm.tests.orm_correctness;

private import std.process: environment;
private import std.typecons: Nullable, nullable;
private import std.exception: assertThrown;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related,
    many2many, autoHydrate;
private import peque.orm;
private import peque.orm.sql: ormPkColName;


// #4 (compile-time): a model with zero non-PK column fields must be rejected —
// both upsert() and update() would emit an empty SET clause. The static asserts
// in those methods make CRUDMixin (hence Repository) fail to instantiate.
@model("occ_pk_only")
struct OccPkOnly { @primaryKey int id; }
unittest {
    static assert(!__traits(compiles, Repository!(OccPkOnly, Connection)),
        "a zero-non-PK-column model must not form a Repository (empty SET guard)");
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


// ===========================================================================
// #1 — @field override on the primary key
// ===========================================================================

@model("occ_pk")
struct OccPk {
    @primaryKey @field("uid") int    id;    // DB column is "uid", not "id"
    @field                    string name;
}
alias OccPkReg = Registry!(Bind!(OccPk, ModelRepo!OccPk));

// CTFE: the PK column name must reflect the @field override.
unittest {
    static assert(ormPkColName!OccPk() == "uid",
        "ormPkColName must honor @field(\"uid\") on the primary key");
}

// Integration: insert/find/exists must all agree on the "uid" column.
unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_pk;");
    c.exec(schemaSQL!OccPkReg());
    auto repo = Repository!(OccPk, Connection)(&c);

    auto seed = OccPk(0, "hello");
    auto rec  = repo.insert(seed);
    assert(rec.id > 0, "RETURNING must populate the PK via the uid column");

    auto got = repo.findById(rec.id);
    assert(!got.isNull);
    assert(got.get.name == "hello");
    assert(repo.existsById(rec.id));
}


// ===========================================================================
// #2 — where!"field"(null Nullable) → IS NULL / .ne(null) → IS NOT NULL
// ===========================================================================

@model("occ_null")
struct OccNull {
    @primaryKey int             id;
    @field      string          name;
    @field      Nullable!string note;
}
alias OccNullReg = Registry!(Bind!(OccNull, ModelRepo!OccNull));

private Repository!(OccNull, Connection) seedNull(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS occ_null;");
    c.exec(schemaSQL!OccNullReg());
    auto repo = Repository!(OccNull, Connection)(&c);
    auto r1 = OccNull(0, "has-note", "hello".nullable);
    auto r2 = OccNull(0, "no-note",  Nullable!string.init);
    repo.insert(r1);
    repo.insert(r2);
    return repo;
}

unittest {
    auto c    = makeConn();
    auto repo = seedNull(c);

    // where!"note"(empty Nullable) must match the NULL row via IS NULL — a
    // literal `note = NULL` would match nothing.
    auto nulls = repo.query().where!"note"(Nullable!string.init).all();
    assert(nulls.length == 1, "where!(null) must map to IS NULL");
    assert(nulls[0].name == "no-note");

    // F!"note".ne(empty Nullable) must match the non-NULL row via IS NOT NULL.
    auto notNulls = repo.query().where(F!(OccNull, "note").ne(Nullable!string.init)).all();
    assert(notNulls.length == 1, "ne(null) must map to IS NOT NULL");
    assert(notNulls[0].name == "has-note");

    // A present Nullable still binds a normal parameter.
    auto has = repo.query().where!"note"("hello".nullable).all();
    assert(has.length == 1);
    assert(has[0].name == "has-note");
}


// ===========================================================================
// #4 — set!"field" twice (last-write-wins) via QuerySet.update()
// ===========================================================================

unittest {
    auto c    = makeConn();
    auto repo = seedNull(c);
    auto rec  = repo.query().where!"name"("has-note").first();
    assert(!rec.isNull);

    // Two set!() calls on the same column must collapse to one assignment
    // (last wins), not emit `name = $1, name = $2`.
    auto n = repo.query().where!"id"(rec.get.id)
                 .set!"name"("first")
                 .set!"name"("second")
                 .update();
    assert(n == 1);
    assert(repo.findById(rec.get.id).get.name == "second");
}


// ===========================================================================
// #3 — @many2many prefetch: ambiguous junction id + self-referential m2m
// ===========================================================================

@model("occ_tag")
struct OccTag {
    @primaryKey int    id;
    @field      string name;
}

@model("occ_doc")
struct OccDoc {
    @primaryKey int    id;
    @field      string title;
    // Junction table occ_doc_tag intentionally has its OWN `id` column so the
    // (previously unqualified) target SELECT list would be ambiguous.
    @many2many!(OccTag, "occ_doc_tag", "doc_id", "tag_id") OccTag[] tags;
}
alias OccDocReg = Registry!(
    Bind!(OccTag, ModelRepo!OccTag),
    Bind!(OccDoc, ModelRepo!OccDoc),
);

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_doc_tag;");
    c.exec("DROP TABLE IF EXISTS occ_doc;");
    c.exec("DROP TABLE IF EXISTS occ_tag;");
    c.exec(schemaSQL!OccDocReg());
    // Junction with its own serial `id` — the collision the fix guards against.
    c.exec("
        CREATE TABLE occ_doc_tag (
            id      serial PRIMARY KEY,
            doc_id  int REFERENCES occ_doc(id),
            tag_id  int REFERENCES occ_tag(id)
        );
        INSERT INTO occ_tag (name) VALUES ('red'), ('green'), ('blue');
        INSERT INTO occ_doc (title) VALUES ('Doc A'), ('Doc B');
        INSERT INTO occ_doc_tag (doc_id, tag_id)
            SELECT d.id, t.id FROM occ_doc d, occ_tag t
            WHERE d.title = 'Doc A' AND t.name IN ('red', 'green');
        INSERT INTO occ_doc_tag (doc_id, tag_id)
            SELECT d.id, t.id FROM occ_doc d, occ_tag t
            WHERE d.title = 'Doc B' AND t.name = 'blue';
    ");

    auto repo = Repository!(OccDoc, Connection)(&c);
    auto docs = repo.query().orderBy("_m.title ASC").prefetch!("tags").all();
    assert(docs.length == 2);
    assert(docs[0].title == "Doc A");
    assert(docs[0].tags.length == 2, "target columns must be unambiguous despite junction.id");
    assert(docs[1].title == "Doc B");
    assert(docs[1].tags.length == 1);
    assert(docs[1].tags[0].name == "blue");
}

// Self-referential many2many: friends of a person.
@model("occ_person")
struct OccPerson {
    @primaryKey int    id;
    @field      string name;
    @many2many!(OccPerson, "occ_friend", "person_id", "friend_id") OccPerson[] friends;
}
alias OccPersonReg = Registry!(Bind!(OccPerson, ModelRepo!OccPerson));

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_friend;");
    c.exec("DROP TABLE IF EXISTS occ_person;");
    c.exec(schemaSQL!OccPersonReg());
    c.exec("
        CREATE TABLE occ_friend (
            person_id int REFERENCES occ_person(id),
            friend_id int REFERENCES occ_person(id)
        );
        INSERT INTO occ_person (name) VALUES ('Ann'), ('Bob'), ('Cara');
        -- Ann is friends with Bob and Cara; Bob with Cara.
        INSERT INTO occ_friend (person_id, friend_id)
            SELECT p.id, f.id FROM occ_person p, occ_person f
            WHERE p.name = 'Ann' AND f.name IN ('Bob', 'Cara');
        INSERT INTO occ_friend (person_id, friend_id)
            SELECT p.id, f.id FROM occ_person p, occ_person f
            WHERE p.name = 'Bob' AND f.name = 'Cara';
    ");

    auto repo   = Repository!(OccPerson, Connection)(&c);
    auto people = repo.query().orderBy("_m.name ASC").prefetch!("friends").all();
    assert(people.length == 3);
    assert(people[0].name == "Ann");
    assert(people[0].friends.length == 2, "self-key alias must stitch the right rows");
    assert(people[1].name == "Bob");
    assert(people[1].friends.length == 1);
    assert(people[2].name == "Cara");
    assert(people[2].friends.length == 0);
}


// ===========================================================================
// #5 — select!DTO longest-prefix relation resolution (partner vs partnerCompany)
// ===========================================================================

@model("occ_org")
struct OccOrg {
    @primaryKey int    id;
    @field      string name;
}

@model("occ_rec")
struct OccRec {
    @primaryKey                 int             id;
    @field                      string          title;
    @many2one!(OccOrg)          Nullable!int    partnerId;
    @related("partnerId")       Nullable!OccOrg partner;
    @many2one!(OccOrg)          Nullable!int    partnerCompanyId;
    @related("partnerCompanyId") Nullable!OccOrg partnerCompany;
}
alias OccRecReg = Registry!(
    Bind!(OccOrg, ModelRepo!OccOrg),
    Bind!(OccRec, ModelRepo!OccRec),
);

@autoHydrate
struct OccRecDTO {
    int    id;
    string title;
    string partnerName;         // partner_name        → partner.name
    string partnerCompanyName;  // partner_company_name → partnerCompany.name
}

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_rec;");
    c.exec("DROP TABLE IF EXISTS occ_org;");
    c.exec(schemaSQL!OccRecReg());

    auto orgRepo = Repository!(OccOrg, Connection)(&c);
    auto acmeSeed = OccOrg(0, "Acme");
    auto glbxSeed = OccOrg(0, "Globex");
    auto acme    = orgRepo.insert(acmeSeed);
    auto globex  = orgRepo.insert(glbxSeed);

    auto recRepo = Repository!(OccRec, Connection)(&c);
    OccRec recSeed;
    recSeed.title            = "R1";
    recSeed.partnerId        = acme.id.nullable;
    recSeed.partnerCompanyId = globex.id.nullable;
    recRepo.insert(recSeed);

    auto dtos = recRepo.query().orderBy("_m.title ASC").select!OccRecDTO();
    assert(dtos.length == 1);
    assert(dtos[0].title == "R1");
    // The bug bound partner_company_name to `partner` (prefix partner_), leaving
    // a bogus `company_name` leaf. Longest-prefix binds it to partnerCompany.
    assert(dtos[0].partnerName == "Acme");
    assert(dtos[0].partnerCompanyName == "Globex");
}
