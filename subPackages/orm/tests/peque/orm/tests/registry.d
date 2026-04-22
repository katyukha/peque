/** Integration tests for peque:orm Phase 4c — Registry, @defaultOrder.
  *
  * Covers:
  *  - ModelRepo!M as a Bind target
  *  - Custom single-Ctx-param repo as a Bind target
  *  - Registry + RegistryRepoFor lookup
  *  - MergeRegistries combining two registries
  *  - RegistryRepoFor used directly (application-defined context pattern)
  *  - @defaultOrder UDA on model — findAll ORDER BY
  *  - Per-repo enum defaultOrder override
  **/
module peque.orm.tests.registry;

private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection, Transaction, OnSuccess, IsolationLevel;
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


// D doesn't allow chaining ! instantiations: RegistryRepoFor!(AppReg, Tag)!Ctx
// won't parse. Resolve the lookup once into a plain alias, then instantiate it.
private alias TagRepoTpl = RegistryRepoFor!(AppReg, Tag);


// ---------------------------------------------------------------------------
// RegistryRepoFor — CRUD via registry lookup (application-defined context pattern)
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = TagRepoTpl!Connection(&c);

    auto tags = repo.findAll();
    assert(tags.length == 3);

    auto tpl = Tag(0, "Delta", 4);
    auto ins = repo.insert(tpl);
    assert(ins.id >= 1);
    assert(ins.name == "Delta");

    ins.priority = 99;
    repo.update(ins);
    assert(repo.findById(ins.id).get.priority == 99);

    repo.deleteById(ins.id);
    assert(repo.findById(ins.id).isNull);
}


// ---------------------------------------------------------------------------
// Custom TagRepo method accessible via RegistryRepoFor
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = TagRepoTpl!Connection(&c);

    auto filtered = repo.findByMinPriority(2);
    assert(filtered.length == 2);   // priority 2 and 3
}


// ---------------------------------------------------------------------------
// Transaction — repos bound to Transaction share the same transaction
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = TagRepoTpl!Connection(&c);

    c.transaction((ref Transaction tx) {
        auto txRepo = TagRepoTpl!Transaction(&tx);
        auto t1 = Tag(0, "TxA", 10);
        auto t2 = Tag(0, "TxB", 20);
        txRepo.insert(t1);
        txRepo.insert(t2);
    });

    // Original 3 + 2 inserted in transaction
    assert(repo.findAll().length == 5);
}

unittest {
    auto c    = makeConn();
    setupTables(c);
    auto repo = TagRepoTpl!Connection(&c);

    // Transaction rolled back on exception — inserts must not be visible
    try {
        c.transaction((ref Transaction tx) {
            auto txRepo = TagRepoTpl!Transaction(&tx);
            auto t = Tag(0, "RollMe", 99);
            txRepo.insert(t);
            throw new Exception("deliberate rollback");
        });
    } catch (Exception) {}

    assert(repo.findAll().length == 3);  // unchanged
}

unittest {
    // OnSuccess.rollback (dry-run)
    auto c    = makeConn();
    setupTables(c);
    auto repo = TagRepoTpl!Connection(&c);

    c.transaction!(OnSuccess.rollback)((ref Transaction tx) {
        auto txRepo = TagRepoTpl!Transaction(&tx);
        auto t = Tag(0, "DryRun", 0);
        txRepo.insert(t);
    });

    assert(repo.findAll().length == 3);
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
