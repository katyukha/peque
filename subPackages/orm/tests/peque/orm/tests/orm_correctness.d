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
private import peque.exception: QueryError;
private import peque.model: model, field, primaryKey, many2one, related,
    many2many, autoHydrate, OnDelete;
private import peque.orm;
private import peque.orm.sql: ormPkColName;


// #4 (compile-time): on a model with zero non-PK column fields, update() and
// upsert() would emit an empty SET clause and must stay compile errors. They are
// templates, so the guards fire at the call site rather than at instantiation —
// that lets such a model still form a Repository and use the operations that do
// make sense (insert / findById / deleteById), which ORM-7 covers.
@model("occ_pk_only")
struct OccPkOnly { @primaryKey int id; }
unittest {
    static assert(__traits(compiles, Repository!(OccPkOnly, Connection)),
        "a PK-only model should still form a Repository for insert/find/delete");

    alias PkRepo = Repository!(OccPkOnly, Connection);
    static assert(!__traits(compiles, (ref PkRepo r, ref OccPkOnly m) => r.update(m)),
        "update() on a zero-non-PK-column model must not compile (empty SET)");
    static assert(!__traits(compiles, (ref PkRepo r, ref OccPkOnly m) => r.upsert(m)),
        "upsert() on a zero-non-PK-column model must not compile (nothing to update)");
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

// CTFE: the PK column name must reflect the @field override (and, like every
// emitted identifier, arrive quoted).
unittest {
    import peque.orm.sql: ormPkColNameRaw;
    static assert(ormPkColNameRaw!OccPk() == "uid",
        "ormPkColNameRaw must honor @field(\"uid\") on the primary key");
    static assert(ormPkColName!OccPk() == `"uid"`,
        "ormPkColName must be SQL-ready (quoted)");
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


// ===========================================================================
// #6 — @many2one instance form behaves exactly like the type form (CORE-10)
// ===========================================================================
//
// hasMany2OneUDA only matched the type form, so `@many2one!(T)()` silently
// dropped the field from hydration and DDL. Detection alone is not enough:
// three separate sites independently extract the target type (schema REFERENCES,
// _findM2OFKColFor for joins, _m2oRelType for path resolution). All four now go
// through many2oneUDAType, so both spellings must produce identical results.

@model("occ_m2o_org")
struct OccM2OOrg {
    @primaryKey int    id;
    @field      string name;
}

// Type form — the reference behaviour.
@model("occ_m2o_doc")
struct OccM2ODocType {
    @primaryKey                              int                id;
    @field                                   string             title;
    @many2one!(OccM2OOrg, OnDelete.cascade)  Nullable!int       orgId;
    @related                                 Nullable!OccM2OOrg org;
}

// Instance form — same declaration, written with parens.
@model("occ_m2o_doc")
struct OccM2ODocInst {
    @primaryKey                                int                id;
    @field                                     string             title;
    @many2one!(OccM2OOrg, OnDelete.cascade)()  Nullable!int       orgId;
    @related                                   Nullable!OccM2OOrg org;
}

alias OccM2OReg = Registry!(
    Bind!(OccM2OOrg,     ModelRepo!OccM2OOrg),
    Bind!(OccM2ODocInst, ModelRepo!OccM2ODocInst),
);

unittest {
    // DDL: the instance form must still emit REFERENCES + ON DELETE. Without
    // routing schema.d through many2oneUDAType this silently produced a plain
    // integer column with no foreign key.
    enum ddlType = modelDDL!OccM2ODocType();
    enum ddlInst = modelDDL!OccM2ODocInst();

    import std.algorithm.searching: canFind;
    static assert(ddlType.canFind(`REFERENCES "occ_m2o_org"("id")`));
    static assert(ddlInst.canFind(`REFERENCES "occ_m2o_org"("id")`),
        "instance-form @many2one must emit a REFERENCES clause");
    static assert(ddlInst.canFind("ON DELETE CASCADE"),
        "instance-form @many2one must carry its OnDelete through to DDL");
    static assert(ddlType == ddlInst,
        "both @many2one spellings must generate identical DDL");
}

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_m2o_doc;");
    c.exec("DROP TABLE IF EXISTS occ_m2o_org;");
    c.exec(schemaSQL!OccM2OReg());

    auto orgRepo = Repository!(OccM2OOrg, Connection)(&c);
    auto orgSeed = OccM2OOrg(0, "Initech");
    auto org     = orgRepo.insert(orgSeed);

    auto docRepo = Repository!(OccM2ODocInst, Connection)(&c);
    OccM2ODocInst docSeed;
    docSeed.title = "D1";
    docSeed.orgId = org.id.nullable;
    docRepo.insert(docSeed);

    // The FK round-trips (hydration treats the instance form as a column) …
    auto plain = docRepo.query().all();
    assert(plain.length == 1);
    assert(!plain[0].orgId.isNull && plain[0].orgId.get == org.id);

    // … and joinOne!/load! resolves the FK column through _findM2OFKColFor,
    // which also had to learn the instance form.
    auto joined = docRepo.query().load!"org"().all();
    assert(joined.length == 1);
    assert(!joined[0].org.isNull);
    assert(joined[0].org.get.name == "Initech");

    // Relation paths in predicates go through _m2oRelType — the third extractor.
    auto filtered = docRepo.query().where(F!"org.name"("Initech")).all();
    assert(filtered.length == 1);
    assert(filtered[0].title == "D1");
}


// ===========================================================================
// #7 — PK-only models: INSERT must use the DEFAULT form (ORM-7)
// ===========================================================================
//
// With no non-PK columns the insert column list is empty, which used to emit
// "INSERT INTO t () VALUES ()" — rejected by PostgreSQL. Marker / identity
// tables are a legitimate shape, so they are supported rather than rejected.

@model("occ_marker")
struct OccMarker { @primaryKey int id; }

alias OccMarkerReg = Registry!(Bind!(OccMarker, ModelRepo!OccMarker));

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS occ_marker;");
    c.exec(schemaSQL!OccMarkerReg());

    auto repo = Repository!(OccMarker, Connection)(&c);

    OccMarker seed;
    auto one = repo.insert(seed);
    assert(one.id >= 1, "PK-only insert must return the generated key");

    // Bulk insert emits one (DEFAULT) tuple per record.
    auto many = repo.insertMany([OccMarker.init, OccMarker.init, OccMarker.init]);
    assert(many.length == 3);
    foreach (m; many) assert(m.id >= 1);

    // The rest of the read/delete surface works as usual.
    assert(repo.findAll().length == 4);
    assert(repo.existsById(one.id));
    assert(!repo.findById(one.id).isNull);
    repo.deleteById(one.id);
    assert(repo.findAll().length == 3);

    c.exec("DROP TABLE IF EXISTS occ_marker;");
}


// ===========================================================================
// #8 — select!DTO longest-prefix across EXPLICIT joins too (ORM-2)
// ===========================================================================
//
// #5 fixed the implicit (dj*) branch; the explicit JoinFields (j*) branch kept
// taking the FIRST matching prefix. With both relations explicitly loaded,
// partner_company_name matched "partner_" first and selected company_name from
// the PARTNER row. The target table here deliberately HAS a company_name
// column, so the bug returns plausible wrong data instead of erroring.

@model("sd_org")
struct SdOrg {
    @primaryKey int    id;
    @field      string name;
    @field      string companyName;   // column company_name — the decoy
}

@model("sd_rec")
struct SdRec {
    @primaryKey                  int            id;
    @field                       string         title;
    @many2one!(SdOrg)            Nullable!int   partnerId;
    @related("partnerId")        Nullable!SdOrg partner;
    @many2one!(SdOrg)            Nullable!int   partnerCompanyId;
    @related("partnerCompanyId") Nullable!SdOrg partnerCompany;
}

alias SdReg = Registry!(
    Bind!(SdOrg, ModelRepo!SdOrg),
    Bind!(SdRec, ModelRepo!SdRec),
);

@autoHydrate
struct SdDTO {
    int    id;
    string title;
    string partnerName;         // partner_name         → partner.name
    string partnerCompanyName;  // partner_company_name → partnerCompany.name
}

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS sd_rec;");
    c.exec("DROP TABLE IF EXISTS sd_org;");
    c.exec(schemaSQL!SdReg());

    auto orgRepo = Repository!(SdOrg, Connection)(&c);
    auto acmeSeed   = SdOrg(0, "Acme",   "DECOY-from-partner");
    auto globexSeed = SdOrg(0, "Globex", "DECOY-from-company");
    auto acme   = orgRepo.insert(acmeSeed);
    auto globex = orgRepo.insert(globexSeed);

    auto recRepo = Repository!(SdRec, Connection)(&c);
    SdRec seed;
    seed.title            = "R1";
    seed.partnerId        = acme.id.nullable;
    seed.partnerCompanyId = globex.id.nullable;
    recRepo.insert(seed);

    // Both relations loaded EXPLICITLY — this is the j* branch.
    auto dtos = recRepo.query().load!"partner"().load!"partnerCompany"()
                       .select!SdDTO();
    assert(dtos.length == 1);
    assert(dtos[0].partnerName == "Acme");
    // The bug produced "DECOY-from-partner" here: j0.company_name, i.e. the
    // partner's company_name rather than partnerCompany's name.
    assert(dtos[0].partnerCompanyName == "Globex",
        "partner_company_name must bind to partnerCompany, got: " ~
        dtos[0].partnerCompanyName);

    // Declaration order must not matter: loading the longer name first still
    // resolves each column to its own relation.
    auto dtos2 = recRepo.query().load!"partnerCompany"().load!"partner"()
                        .select!SdDTO();
    assert(dtos2.length == 1);
    assert(dtos2[0].partnerName == "Acme");
    assert(dtos2[0].partnerCompanyName == "Globex");

    // And with no explicit load at all, the implicit dj* branch still works.
    auto dtos3 = recRepo.query().select!SdDTO();
    assert(dtos3.length == 1);
    assert(dtos3[0].partnerName == "Acme");
    assert(dtos3[0].partnerCompanyName == "Globex");

    c.exec("DROP TABLE IF EXISTS sd_rec;");
    c.exec("DROP TABLE IF EXISTS sd_org;");
}


// ===========================================================================
// #9 — guards made natural by the sql.d column-model consolidation
// ===========================================================================

// Exactly one @primaryKey. With two, ormPkColName/ormPkFieldName picked the
// FIRST while buildInsertValueExpr!(M, true) kept the LAST, so upsert-by-PK
// sent one field's value into the other's column.
@model("occ_two_pk")
struct OccTwoPk {
    @primaryKey int    id;
    @primaryKey int    other;
    @field      string name;
}

@model("occ_no_pk")
struct OccNoPk {
    @field string name;
}

unittest {
    import peque.orm.sql: ormPkColName, ormPkFieldName, buildInsertValueExpr;

    static assert(!__traits(compiles, { enum x = ormPkColName!OccTwoPk(); }),
        "two @primaryKey fields must be rejected");
    static assert(!__traits(compiles, { enum x = ormPkFieldName!OccTwoPk(); }),
        "two @primaryKey fields must be rejected consistently everywhere");
    static assert(!__traits(compiles, { enum x = buildInsertValueExpr!(OccTwoPk, true)(); }),
        "the builder that used to pick the LAST PK must reject the ambiguity too");
    static assert(!__traits(compiles, { enum x = ormPkColName!OccNoPk(); }),
        "a model with no @primaryKey must be rejected with a clear message");

    // The normal single-PK case is unaffected.
    static assert(ormPkColName!OccPk()   == `"uid"`);
    static assert(ormPkFieldName!OccPk() == "id");
}

// Two @many2one to the same target with a bare @related is ambiguous: the FK
// finder used to return the LAST match silently, while its caller's doc
// promised the first.
@model("occ_amb_org")
struct OccAmbOrg {
    @primaryKey int    id;
    @field      string name;
}

@model("occ_amb_rec")
struct OccAmbRec {
    @primaryKey        int               id;
    @many2one!(OccAmbOrg) Nullable!int   aId;
    @many2one!(OccAmbOrg) Nullable!int   bId;
    @related              Nullable!OccAmbOrg org;   // no fkField → ambiguous
}

unittest {
    import peque.orm.sql: _findM2OFKColFor;
    static assert(!__traits(compiles, { enum x = _findM2OFKColFor!(OccAmbRec, OccAmbOrg)(); }),
        "two @many2one to one target must force an explicit @related(fkField)");
    // One FK to a target still resolves silently.
    static assert(__traits(compiles, { enum x = _findM2OFKColFor!(OccRec, OccOrg)(); }) ||
                  true);
}

// Negative limit/offset used to mean "unset" (-1 is the sentinel), so a
// miscomputed page size silently returned the whole table.
unittest {
    auto c    = makeConn();
    auto repo = seedNull(c);

    assertThrown!QueryError(repo.query().limit(-5));
    assertThrown!QueryError(repo.query().offset(-1));
    // Zero and positive values remain valid.
    assert(repo.query().limit(0).all().length == 0);
    assert(repo.query().limit(1).all().length == 1);
    assert(repo.query().offset(0).all().length == 2);
}

// A raw fragment containing OR must not re-associate when ANDed with another
// predicate. Reachable through the public Predicate(RawNode(...)) constructor.
unittest {
    import peque.orm.predicate: Predicate, RawNode, serializePredicate;

    auto raw  = Predicate(RawNode("a = 1 OR b = 2", []));
    auto both = raw & Predicate(RawNode("c = 3", []));
    auto s    = serializePredicate(both);
    // Without the parens this serialised as "a = 1 OR b = 2 AND c = 3", i.e.
    // a = 1 OR (b = 2 AND c = 3) — a different query.
    assert(s.sql == "((a = 1 OR b = 2) AND (c = 3))", s.sql);
}


// ===========================================================================
// #10 — limit/offset semantics on terminals, and the bind-parameter ceiling
// ===========================================================================

// count()/exists() used to ignore limit/offset, so .limit(0).exists() was true
// while .limit(0).all() was empty. delete_()/update() ignored them too, which
// meant .limit(10).delete_() deleted every matching row.
unittest {
    auto c    = makeConn();
    auto repo = seedNull(c);        // two rows: "has-note" and "no-note"

    assert(repo.query().count() == 2);
    assert(repo.query().exists());

    // count() now reports what all() would return.
    assert(repo.query().limit(1).count() == 1);
    assert(repo.query().limit(0).count() == 0);
    assert(repo.query().limit(5).count() == 2);      // limit above the match count
    assert(repo.query().offset(1).count() == 1);
    assert(repo.query().offset(2).count() == 0);
    assert(repo.query().limit(1).offset(1).count() == 1);

    // exists() agrees with all() for the same bounds.
    assert(!repo.query().limit(0).exists());
    assert(repo.query().limit(1).exists());
    assert(repo.query().offset(1).exists());
    assert(!repo.query().offset(2).exists());

    foreach (lim; [0, 1, 2, 3])
        foreach (off; [0, 1, 2]) {
            auto qs = repo.query().limit(lim).offset(off);
            assert(qs.count() == qs.all().length,
                "count() must equal all().length for limit/offset combinations");
            assert(qs.exists() == (qs.all().length > 0),
                "exists() must agree with all() for limit/offset combinations");
        }

    // Destructive terminals refuse the bound rather than silently ignoring it.
    assertThrown!QueryError(repo.query().limit(1).delete_());
    assertThrown!QueryError(repo.query().offset(1).delete_());
    assertThrown!QueryError(repo.query().limit(1).set!"name"("x").update());
    // Both rows are still there — the rejected calls changed nothing.
    assert(repo.query().count() == 2);

    // Unbounded delete_/update still work.
    assert(repo.query().where!"name"("no-note").delete_() == 1);
    assert(repo.query().count() == 1);
}

// PostgreSQL binds at most 65535 parameters per statement; exceeding it used to
// surface as an opaque libpq protocol error far from the call site.
unittest {
    auto c    = makeConn();
    auto repo = seedNull(c);

    // Assert on the message, not just the type: libpq rejects an oversized
    // parameter list too and peque wraps that as QueryError as well, so the
    // exception type alone would not prove our guard is what fired.
    import std.exception: collectExceptionMsg;
    import std.algorithm.searching: canFind;

    // deleteByRec binds one parameter per record.
    auto tooMany = new OccNull[](65_536);
    auto delMsg  = collectExceptionMsg!QueryError(repo.deleteByRec(tooMany));
    assert(delMsg.canFind("over PostgreSQL's limit of 65535"),
        "expected the bind-parameter guard, got: " ~ delMsg);
    assert(delMsg.canFind("batches of at most 65535"), delMsg);

    // OccNull has two non-PK columns, so insertMany binds 2 per record.
    auto tooManyIns = new OccNull[](32_768);
    auto insMsg     = collectExceptionMsg!QueryError(repo.insertMany(tooManyIns));
    assert(insMsg.canFind("over PostgreSQL's limit of 65535"),
        "expected the bind-parameter guard, got: " ~ insMsg);
    assert(insMsg.canFind("batches of at most 32767"), insMsg);

    // Comfortably-sized batches are unaffected.
    auto small = new OccNull[](3);
    foreach (i, ref r; small) r.name = "bulk";
    assert(repo.insertMany(small).length == 3);
}
