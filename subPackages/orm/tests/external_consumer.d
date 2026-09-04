/** Compiles the public API from OUTSIDE the `peque.orm` package.
  *
  * `package(peque.orm)` protection is decided by module NAME, so every other
  * test module — `peque.orm.tests.*` — is inside the package and can reach
  * internals a real consumer cannot. A mixin template is where that matters:
  * its body is compiled in the INSTANTIATING module's scope, so anything it
  * references must be reachable from there.
  *
  * That is invisible to a test living inside the package. A selective import
  * of a `package(peque.orm)` symbol inside CRUDMixin, say
  * `import peque.orm.schema : _partialUniqueIndexPred;`, resolves fine for
  * peque's own tests and fails for everyone else with "member
  * _partialUniqueIndexPred is not visible from module …".
  *
  * This module is named outside the package on purpose. Anything a consumer
  * would write belongs here — especially direct `mixin CRUDMixin!`, which the
  * in-package tests do exercise but cannot exercise honestly.
  **/
module external_consumer;

private import std.process: environment;
private import std.typecons: Nullable, nullable;

private import peque;
private import peque.orm;


@model("ext_session")
private struct ExtSession {
    @primaryKey            int    id;
    @field @unique         string token;
    @field                 int    userId;
    @field @uniqueIndex(where: "NOT revoked") string slug;
    @field                 bool   revoked;
}

@model("ext_tag")
private struct ExtTag {
    @primaryKey int    id;
    @field      string name;
}

// A consumer's own repository type, built from the mixin rather than from the
// ready-made Repository — this is the shape that broke.
private struct SessionRepo(Ctx) if (isQueryContext!Ctx) {
    private Ctx* _ctx;
    this(Ctx* ctx) { _ctx = ctx; }
    mixin CRUDMixin!(ExtSession, Ctx);
}

// And a consumer-side registry, as the README documents it.
private alias ExtReg = Registry!(
    Bind!(ExtSession, ModelRepo!ExtSession),
    Bind!(ExtTag,     ModelRepo!ExtTag),
);

@autoHydrate
private struct ExtDTO {
    int    id;
    string token;
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

// Instantiating the mixin IS the assertion — every symbol its body touches must
// be reachable from a module outside peque.orm.
//
// Deliberately not wrapped in `static assert(is(...))`: is() swallows the
// instantiation error, leaving only "is(SessionRepo!(Connection)) is false" with
// no clue which symbol was unreachable. A plain declaration reports the real
// message — "member _x is not visible from module external_consumer".
// An alias completes the type (and so runs the mixin) without constructing it —
// ModelRepo disables default construction. Template members such as
// insert!(OnConflict…) are only analysed when called, which the runtime test
// below does.
private alias _MixinProbe = SessionRepo!Connection;

// D cannot chain ! instantiations — resolve the lookup into an alias first.
private alias _ExtRepoTpl    = RegistryRepoFor!(ExtReg, ExtSession);
private alias _RegistryProbe = _ExtRepoTpl!Connection;

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS ext_session`);
    c.exec(`DROP TABLE IF EXISTS ext_tag`);
    c.exec(schemaSQL!ExtReg());

    auto repo = SessionRepo!Connection(&c);

    // Plain CRUD through the consumer's own mixin.
    ExtSession s;
    s.token = "t1"; s.userId = 7; s.slug = "a";
    auto saved = repo.insert(s);
    assert(saved.id > 0);
    assert(repo.findById(saved.id).get.token == "t1");
    assert(repo.existsById(saved.id));

    auto upd = saved;
    upd.userId = 8;
    repo.update(upd);
    assert(repo.findById(saved.id).get.userId == 8);

    // The conflict API, whose internals are what leaked.
    ExtSession dup;
    dup.token = "t1"; dup.userId = 9; dup.slug = "b";
    assert(repo.insert!(OnConflict.doNothing)(dup).isNull);
    assert(repo.insert!(OnConflict.doNothing, Target.columns!("token"))(dup).isNull);

    ExtSession up2;
    up2.token = "t1"; up2.userId = 10; up2.slug = "c";
    assert(repo.insert!(OnConflict.doUpdate, Target.columns!("token"))(up2).userId == 10);

    // Partial unique index — this path reaches _partialUniqueIndexPred, the
    // symbol that was unreachable from here.
    ExtSession p;
    p.token = "t2"; p.userId = 1; p.slug = "a";
    assert(repo.upsert!"slug"(p).userId == 1);

    // QuerySet surface, including the expression and conflict-adjacent bits.
    assert(repo.query().where!"userId"(1).count() == 1);
    assert(repo.query().where(F!(ExtSession, "userId").lt(F!(ExtSession, "id"))).count() >= 0);
    assert(repo.query().where((F!(ExtSession, "userId") + 1).gt(0)).count() >= 1);
    assert(repo.query().select!ExtDTO().length >= 1);
    assert(!repo.query().first().isNull);

    // DDL generation from outside the package.
    static assert(modelDDL!ExtSession().length > 0);
    static assert(schemaSQL!ExtReg().length > 0);

    c.exec(`DROP TABLE IF EXISTS ext_session`);
    c.exec(`DROP TABLE IF EXISTS ext_tag`);
}


// ---------------------------------------------------------------------------
// ormColumnName — the supported field -> column resolver
// ---------------------------------------------------------------------------

// Code outside peque that reads a model's UDAs has to resolve field names to
// columns before deriving anything from them. Reimplementing the rule is how a
// consumer silently drifts: one downstream caller composed PostgreSQL's
// generated constraint name straight from @uniqueTogether's list and, once that
// list held D field names, predicted <table>_projectId_userId_key for a
// constraint the server calls <table>_project_id_user_id_key. It compiled
// clean. This is the resolver that makes that unnecessary, and it lives here —
// outside peque.orm — because that is the only place its visibility is real.
@model("ec_col_name")
@uniqueTogether!("projectId", "userId")
struct EcColName {
    @primaryKey            int    id;
    @field                 int    projectId;
    @field("legacy_UserId") int   userId;
    @field                 string name;
}

unittest {
    static assert(ormColumnName!(EcColName, "projectId") == "project_id");
    static assert(ormColumnName!(EcColName, "name")      == "name");
    // An explicit @field wins, case and all.
    static assert(ormColumnName!(EcColName, "userId")    == "legacy_UserId");
    // The primary key resolves like any other field.
    static assert(ormColumnName!(EcColName, "id")        == "id");
    // An unknown field is a compile error naming the alternatives.
    static assert(!__traits(compiles, ormColumnName!(EcColName, "project_id")));
    static assert(!__traits(compiles, ormColumnName!(EcColName, "nope")));

    // What the downstream caller actually needed: compose a derived identifier
    // from the same list the UDA carries, resolved rather than concatenated raw.
    static foreach (uda; __traits(getAttributes, EcColName)) {
        static if (__traits(compiles, uda.fields)) {
            enum joined = () {
                string r;
                static foreach (f; uda.fields) r ~= "_" ~ ormColumnName!(EcColName, f);
                return r;
            }();
            static assert(joined == "_project_id_legacy_UserId", joined);
        }
    }
}
