/** Integration tests for peque:orm Phase 4c — Registry, Environment, @defaultOrder.
  *
  * Covers:
  *  - ModelRepo!M as a Bind target
  *  - Custom single-Ctx-param repo as a Bind target
  *  - Registry + RegistryRepoFor lookup
  *  - MergeRegistries combining two registries
  *  - Environment.repo!(M) — CRUD through the environment
  *  - Environment.withTransaction — repos inside the delegate share the transaction
  *  - @defaultOrder UDA on model — findAll ORDER BY
  *  - Per-repo enum defaultOrder override
  **/
module peque.orm.tests.registry;

private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection, Transaction, OnSuccess;
private import peque.model: model, field, primaryKey, defaultOrder;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("peque_orm_tags")
@defaultOrder!"name"
struct Tag {
    @primaryKey int    id;
    @field      string name;
    @field      int    priority;
}

@model("peque_orm_notes")
@defaultOrder!("priority DESC", "id")
struct Note {
    @primaryKey int    id;
    @field      string title;
    @field      int    priority;
}


// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

// Custom single-Ctx-param repo for Tag (proves Bind works with non-ModelRepo)
struct TagRepo(Ctx) {
    private Ctx* _ctx;
    this(Ctx* ctx) { _ctx = ctx; }
    mixin CRUDMixin!(Tag, Ctx);

    Tag[] findByMinPriority(int min) {
        import peque.orm.sql: buildSelectList, ormTableName;
        return _ctx.execParams(
            "SELECT " ~ buildSelectList!Tag() ~ " FROM " ~ ormTableName!Tag ~
            " WHERE priority >= $1 ORDER BY priority",
            min).as!(Tag[]);
    }
}

// Per-repo defaultOrder override test
struct NoteRepoDesc(Ctx) {
    private Ctx* _ctx;
    this(Ctx* ctx) { _ctx = ctx; }
    // Override model's @defaultOrder — this repo returns notes by id ASC
    enum string defaultOrder = "id ASC";
    mixin CRUDMixin!(Note, Ctx);
}


// ---------------------------------------------------------------------------
// Registries
// ---------------------------------------------------------------------------

alias TagReg  = Registry!(Bind!(Tag,  TagRepo));
alias NoteReg = Registry!(Bind!(Note, ModelRepo!Note));
alias AppReg  = MergeRegistries!(TagReg, NoteReg);

// Environments
alias AppEnv    = Environment!(AppReg, Connection);
alias AppEnvCtx = Environment!(AppReg, Connection, int);  // AppCtx = int (user id)


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

private void setupTables(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS peque_orm_notes;
        DROP TABLE IF EXISTS peque_orm_tags;
        CREATE TABLE peque_orm_tags (
            id       serial PRIMARY KEY,
            name     varchar(40) NOT NULL,
            priority int NOT NULL DEFAULT 0
        );
        CREATE TABLE peque_orm_notes (
            id       serial PRIMARY KEY,
            title    varchar(80) NOT NULL,
            priority int NOT NULL DEFAULT 0
        );
        INSERT INTO peque_orm_tags  (name, priority)
            VALUES ('Zeta', 3), ('Alpha', 1), ('Beta', 2);
        INSERT INTO peque_orm_notes (title, priority)
            VALUES ('Low',  1), ('High', 3), ('Mid',  2);
    `);
}


// ---------------------------------------------------------------------------
// RegistryRepoFor compile-time lookup
// ---------------------------------------------------------------------------

unittest {
    // TagReg maps Tag → TagRepo (template alias comparison via __traits(isSame))
    static assert(__traits(isSame, RegistryRepoFor!(TagReg, Tag), TagRepo));
    // AppReg (merged) maps Tag → TagRepo and Note → ModelRepo!Note
    static assert(__traits(isSame, RegistryRepoFor!(AppReg, Tag), TagRepo));
    static assert(__traits(isSame, RegistryRepoFor!(AppReg, Note), ModelRepo!Note));
}


// ---------------------------------------------------------------------------
// Environment.repo! — basic CRUD via env
// ---------------------------------------------------------------------------

unittest {
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnv(&c);

    auto tags = env.repo!(Tag).findAll();
    assert(tags.length == 3);

    auto tpl = Tag(0, "Delta", 4);
    auto ins = env.repo!(Tag).insert(tpl);
    assert(ins.id >= 1);
    assert(ins.name == "Delta");

    ins.priority = 99;
    env.repo!(Tag).update(ins);
    assert(env.repo!(Tag).findById(ins.id).get.priority == 99);

    env.repo!(Tag).deleteById(ins.id);
    assert(env.repo!(Tag).findById(ins.id).isNull);
}


// ---------------------------------------------------------------------------
// Custom TagRepo method accessible through Environment
// ---------------------------------------------------------------------------

unittest {
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnv(&c);

    auto filtered = env.repo!(Tag).findByMinPriority(2);
    assert(filtered.length == 2);   // priority 2 and 3
}


// ---------------------------------------------------------------------------
// Environment with AppCtx
// ---------------------------------------------------------------------------

unittest {
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnvCtx(&c, 42);
    assert(env.appCtx == 42);

    // repo still works
    auto tags = env.repo!(Tag).findAll();
    assert(tags.length == 3);
}


// ---------------------------------------------------------------------------
// Environment.withTransaction — both inserts are in the same transaction
// ---------------------------------------------------------------------------

unittest {
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnv(&c);

    env.withTransaction((ref AppEnv.TxEnv txEnv) {
        auto t1 = Tag(0, "TxA", 10);
        auto t2 = Tag(0, "TxB", 20);
        txEnv.repo!(Tag).insert(t1);
        txEnv.repo!(Tag).insert(t2);
    });

    auto all = env.repo!(Tag).findAll();
    // Original 3 + 2 inserted in transaction
    assert(all.length == 5);
}

unittest {
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnv(&c);

    // Transaction rolled back on exception — inserts must not be visible
    try {
        env.withTransaction((ref AppEnv.TxEnv txEnv) {
            auto t = Tag(0, "RollMe", 99);
            txEnv.repo!(Tag).insert(t);
            throw new Exception("deliberate rollback");
        });
    } catch (Exception) {}

    auto all = env.repo!(Tag).findAll();
    assert(all.length == 3);  // unchanged
}

unittest {
    // withTransaction with OnSuccess.rollback (dry-run)
    auto c   = makeConn();
    setupTables(c);
    auto env = AppEnv(&c);

    env.withTransaction!(OnSuccess.rollback)((ref AppEnv.TxEnv txEnv) {
        auto t = Tag(0, "DryRun", 0);
        txEnv.repo!(Tag).insert(t);
    });

    assert(env.repo!(Tag).findAll().length == 3);
}


// ---------------------------------------------------------------------------
// @defaultOrder on model — findAll returns rows in declared order
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = Repository!(Tag, Connection)(&c);

    // @defaultOrder!"name" → ORDER BY name ASC
    auto tags = repo.findAll();
    assert(tags[0].name == "Alpha");
    assert(tags[1].name == "Beta");
    assert(tags[2].name == "Zeta");
}

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = Repository!(Note, Connection)(&c);

    // @defaultOrder!("priority DESC", "id") → priority high first
    auto notes = repo.findAll();
    assert(notes[0].priority == 3);  // High
    assert(notes[1].priority == 2);  // Mid
    assert(notes[2].priority == 1);  // Low
}


// ---------------------------------------------------------------------------
// Per-repo enum defaultOrder overrides the model UDA
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupTables(c);
    // NoteRepoDesc has `enum string defaultOrder = "id ASC"` which overrides
    // Note's @defaultOrder!("priority DESC", "id")
    auto repo = NoteRepoDesc!Connection(&c);
    auto notes = repo.findAll();
    // id ASC: first inserted row has lowest id
    assert(notes[0].title == "Low");
    assert(notes[1].title == "High");
    assert(notes[2].title == "Mid");
}
