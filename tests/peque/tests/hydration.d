/** Integration tests for Phase 4a — struct hydration (ResultRow.as!T).
  *
  * Covers:
  *  - @model struct: @field, @primaryKey, explicit column name override
  *  - @autoHydrate struct: convention mapping, missing columns skipped
  *  - User-defined constructor this(ref ResultRow)
  *  - User-defined factory fromRow(ref ResultRow)
  *  - Nullable fields
  *  - Result.as!(T[]) for all-rows hydration
  *  - INSERT ... RETURNING round-trip
  *  - Static assert fires for unannotated structs (via __traits(compiles))
  **/
module peque.tests.hydration;

private import std.process: environment;
private import std.typecons: Nullable, nullable;

private import peque.connection: Connection;
private import peque.result: ResultRow;
private import peque.exception: ColNotExistsError;
private import std.exception: assertThrown;
private import peque.model: model, field, primaryKey, autoHydrate, many2one;


// ---------------------------------------------------------------------------
// Shared model definitions used across multiple tests
// ---------------------------------------------------------------------------

@model("peque_hydration_items")
struct Item {
    @primaryKey             int    id;
    @field                  string code;
    @field("display_name")  string name;
    @field                  int    score;
}

@model("peque_hydration_items")
struct NullableItem {
    @primaryKey             int             id;
    @field                  string          code;
    @field("display_name")  Nullable!string name;   // NULL → Nullable.init
}

@autoHydrate
struct ItemSummary {
    int    id;
    string code;
    // score is intentionally absent — should be silently skipped
}

struct CustomCtor {
    string label;
    this(ref ResultRow row) {
        label = row["code"].as!string ~ ": " ~ row["display_name"].as!string;
    }
}

struct FactoryMethod {
    string label;
    static FactoryMethod fromRow(ref ResultRow row) {
        return FactoryMethod(row["code"].as!string ~ "/" ~ row["display_name"].as!string);
    }
}


// ---------------------------------------------------------------------------
// Helper
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

private void setupTable(ref Connection c) {
    c.exec("
        DROP TABLE IF EXISTS peque_hydration_items;
        CREATE TABLE peque_hydration_items (
            id           serial PRIMARY KEY,
            code         varchar(10) NOT NULL,
            display_name varchar(40),
            score        int NOT NULL DEFAULT 0
        );
        INSERT INTO peque_hydration_items (code, display_name, score)
        VALUES ('a1', 'Alpha',   10),
               ('b2', 'Beta',    20),
               ('c3',  NULL,     30);
    ");
}


// ---------------------------------------------------------------------------
// @model + @field + @primaryKey hydration
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    // Single-row hydration via ResultRow.as!T
    auto res = c.execParams(
        "SELECT id, code, display_name, score FROM peque_hydration_items WHERE code = $1",
        "a1");

    auto item = res.getRow(0).as!Item;
    assert(item.code  == "a1");
    assert(item.name  == "Alpha");   // @field("display_name") → maps to "name" field
    assert(item.score == 10);
    assert(item.id    >= 1);
}

// @primaryKey column name uses convention (id → id)
unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY id LIMIT 1");
    auto item = res.getRow(0).as!Item;
    assert(item.id >= 1);
    assert(item.code == "a1");
}


// ---------------------------------------------------------------------------
// Result.as!(T[]) — all rows hydration
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    // Exclude the NULL-display_name row (c3) since Item.name is string, not Nullable!string
    auto items = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items
         WHERE display_name IS NOT NULL ORDER BY code")
        .as!(Item[]);

    assert(items.length == 2);
    assert(items[0].code  == "a1");
    assert(items[0].name  == "Alpha");
    assert(items[0].score == 10);
    assert(items[1].code  == "b2");
    assert(items[1].name  == "Beta");
    assert(items[1].score == 20);
}


// ---------------------------------------------------------------------------
// Nullable fields — NULL → Nullable.init, non-NULL → Nullable(value)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    auto items = c.exec(
        "SELECT id, code, display_name FROM peque_hydration_items ORDER BY code")
        .as!(NullableItem[]);

    assert(items.length == 3);
    assert(!items[0].name.isNull);
    assert(items[0].name.get == "Alpha");
    assert(!items[1].name.isNull);
    assert(items[1].name.get == "Beta");
    assert(items[2].name.isNull);     // NULL in DB → Nullable.init
}


// ---------------------------------------------------------------------------
// @autoHydrate — convention mapping, missing columns silently skipped
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    // SELECT only id and code — score is absent but ItemSummary has no score field anyway
    auto summaries = c.exec(
        "SELECT id, code FROM peque_hydration_items ORDER BY code")
        .as!(ItemSummary[]);

    assert(summaries.length == 3);
    assert(summaries[0].id   >= 1);
    assert(summaries[0].code == "a1");
    assert(summaries[1].code == "b2");
    assert(summaries[2].code == "c3");
}

// @autoHydrate silently skips absent columns (score not selected → stays 0)
@autoHydrate
private struct FullItem {
    int    id;
    string code;
    int    score;
}

unittest {
    auto c = makeConn();
    setupTable(c);

    // Deliberately do NOT select score
    auto rows = c.exec("SELECT id, code FROM peque_hydration_items ORDER BY code")
                 .as!(FullItem[]);
    assert(rows[0].score == 0);   // zero/init — silently skipped
    assert(rows[0].code  == "a1");
}


// ---------------------------------------------------------------------------
// User-defined constructor: this(ref ResultRow)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY code");

    auto row0 = res.getRow(0).as!CustomCtor;
    assert(row0.label == "a1: Alpha");

    auto row1 = res.getRow(1).as!CustomCtor;
    assert(row1.label == "b2: Beta");
}


// ---------------------------------------------------------------------------
// User-defined factory: static T fromRow(ref ResultRow)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY code");

    auto item = res.getRow(0).as!FactoryMethod;
    assert(item.label == "a1/Alpha");
}


// ---------------------------------------------------------------------------
// INSERT ... RETURNING round-trip
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    // INSERT with RETURNING returns PGRES_TUPLES_OK — as!T works identically
    auto inserted = c.execParams(
        "INSERT INTO peque_hydration_items (code, display_name, score)
         VALUES ($1, $2, $3)
         RETURNING id, code, display_name, score",
        "z9", "Zeta", 99)
        .as!(Item[]);

    assert(inserted.length == 1);
    assert(inserted[0].code  == "z9");
    assert(inserted[0].name  == "Zeta");
    assert(inserted[0].score == 99);
    assert(inserted[0].id    >= 1);
}


// ---------------------------------------------------------------------------
// Dispatch chain priority: constructor wins over @model
// ---------------------------------------------------------------------------

// Must be at module scope — local types can't be used as template arguments
// in this context (D compiler cannot access the frame pointer from hydration.d).
@model("peque_hydration_items")
private struct ItemWithCtor {
    @primaryKey int    id;
    @field      string code;
    @field      string name;   // would need display_name column but ctor wins
    bool ctorCalled = false;

    this(ref ResultRow row) {
        code       = row["code"].as!string;
        name       = "from_ctor";
        ctorCalled = true;
    }
}

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY code LIMIT 1");
    auto item = res.getRow(0).as!ItemWithCtor;

    // Constructor was called, not UDA hydration
    assert(item.ctorCalled);
    assert(item.name == "from_ctor");
    assert(item.code == "a1");
}


// ---------------------------------------------------------------------------
// Unannotated struct → static assert (tested via __traits(compiles))
// ---------------------------------------------------------------------------

// Must be at module scope for __traits(compiles) to work correctly with templates.
private struct Bare { int id; string name; }

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec("SELECT id, code FROM peque_hydration_items LIMIT 1");
    // ResultRow.as!Bare must not compile — dispatch chain has no matching case
    static assert(!__traits(compiles, res.getRow(0).as!Bare));
}


// ---------------------------------------------------------------------------
// Result.as!(T[]) rejects non-struct element types (CORE-13)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec("SELECT id, code FROM peque_hydration_items");

    // A slice of structs is the only supported form.
    static assert(__traits(compiles, res.as!(Item[])));

    // string is immutable(char)[], so it satisfies `is(T == E[], E)` and used to
    // reach the body, where std.range.ElementType auto-decoded it to dchar and
    // the failure surfaced deep inside ResultRow.as. Now the static assert in
    // Result.as catches it directly.
    static assert(!__traits(compiles, res.as!string));
    static assert(!__traits(compiles, res.as!(char[])));
    static assert(!__traits(compiles, res.as!(int[])));
}


// ---------------------------------------------------------------------------
// @many2one in instance form is a column field (CORE-10)
// ---------------------------------------------------------------------------

// The FK target is irrelevant to hydration — what matters is that both UDA
// spellings mark the field as a DB column. The instance form used to be missed
// by hasMany2OneUDA, so the field was silently skipped and left at .init.
@model("peque_hydration_m2o_parent")
private struct M2OParent {
    @primaryKey int    id;
    @field      string name;
}

@model("peque_hydration_m2o_child")
private struct M2OChildTypeForm {
    @primaryKey            int    id;
    @field                 string code;
    @many2one!(M2OParent)  int    parentId;    // type form
}

@model("peque_hydration_m2o_child")
private struct M2OChildInstanceForm {
    @primaryKey              int    id;
    @field                   string code;
    @many2one!(M2OParent)()  int    parentId;  // instance form — same meaning
}

unittest {
    import peque.model: hasMany2OneUDA;

    // Both spellings must be detected identically.
    static assert(hasMany2OneUDA!(__traits(getMember, M2OChildTypeForm,     "parentId")));
    static assert(hasMany2OneUDA!(__traits(getMember, M2OChildInstanceForm, "parentId")));

    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS peque_hydration_m2o_child");
    c.exec("DROP TABLE IF EXISTS peque_hydration_m2o_parent");
    c.exec("CREATE TABLE peque_hydration_m2o_parent (
                id SERIAL PRIMARY KEY, name TEXT NOT NULL)");
    c.exec("CREATE TABLE peque_hydration_m2o_child (
                id        SERIAL PRIMARY KEY,
                code      TEXT NOT NULL,
                parent_id INTEGER NOT NULL REFERENCES peque_hydration_m2o_parent(id))");
    c.exec("INSERT INTO peque_hydration_m2o_parent (name) VALUES ('p1')");
    c.exec("INSERT INTO peque_hydration_m2o_child (code, parent_id)
            SELECT 'c1', id FROM peque_hydration_m2o_parent");

    auto sql = "SELECT id, code, parent_id FROM peque_hydration_m2o_child";

    auto typed    = c.exec(sql).as!(M2OChildTypeForm[]);
    auto instance = c.exec(sql).as!(M2OChildInstanceForm[]);

    assert(typed.length == 1 && instance.length == 1);
    assert(typed[0].parentId >= 1);
    // The instance form must hydrate the FK, not leave it at .init.
    assert(instance[0].parentId == typed[0].parentId);
    assert(instance[0].code == "c1");

    c.exec("DROP TABLE peque_hydration_m2o_child");
    c.exec("DROP TABLE peque_hydration_m2o_parent");
}


// ---------------------------------------------------------------------------
// fromRow must return T to be selected by the dispatch chain
// ---------------------------------------------------------------------------

// A fromRow returning something else used to satisfy the "does it compile"
// gate, after which the call failed with a bare "cannot implicitly convert"
// instead of falling through to the dispatch-chain static assert.
private struct WrongFromRow {
    string label;
    static int fromRow(ref ResultRow row) { return 42; }
}

// A correct one, to prove the gate still selects case 2.
private struct RightFromRow {
    string label;
    static RightFromRow fromRow(ref ResultRow row) {
        return RightFromRow(row["code"].as!string);
    }
}

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY code");

    // Correct signature is still picked up.
    auto ok = res.getRow(0).as!RightFromRow;
    assert(ok.label == "a1");

    // Wrong return type: no dispatch case applies, so hydration is rejected
    // outright rather than failing deep inside the call.
    static assert(!__traits(compiles, res.getRow(0).as!WrongFromRow),
        "fromRow returning a non-T must not satisfy the dispatch chain");
}


// ---------------------------------------------------------------------------
// Annotated fields without @model — a decode shape, not a table
// ---------------------------------------------------------------------------

// @model marks a table (and is what isModel requires). A projection or a
// RETURNING row needs the same strict, aliasable mapping without claiming one,
// so annotations alone are enough to hydrate.
private struct DecodeShape {
    @primaryKey             int    id;
    @field("display_name")  string name;      // aliased
    @field                  int    score;
}

// No markers at all must still be rejected — the dispatch chain has to
// distinguish "a decode shape" from "someone forgot".
private struct Unmarked { int id; string code; }

unittest {
    auto c = makeConn();
    setupTable(c);

    auto res = c.exec(
        "SELECT id, code, display_name, score FROM peque_hydration_items ORDER BY code");

    auto v = res.getRow(0).as!DecodeShape;
    assert(v.name  == "Alpha", "an explicit @field alias must be honoured");
    assert(v.score == 10);
    assert(v.id    >= 1);

    // Strict like @model: a missing column throws rather than leaving zero.
    auto partial = c.exec("SELECT id, code FROM peque_hydration_items LIMIT 1");
    assertThrown!ColNotExistsError(partial.getRow(0).as!DecodeShape);

    // A struct with no hydration markers stays a compile error.
    static assert(!__traits(compiles, res.getRow(0).as!Unmarked));

    // @autoHydrate still wins when both are present, and stays lenient.
    assert(res.as!(ItemSummary[]).length == 3);
}


// ---------------------------------------------------------------------------
// @field(related: "rel.field") and hydration
//
// A related path is a directive for BUILDING a query, not for decoding one.
// PostgreSQL never returns a dotted column name, so at decode time such a
// member resolves like any other — camelToSnake of its name — which is exactly
// the alias the ORM emits. These pin that contract from the core side: no
// peque.orm here, only hand-written SQL, so the ORM's alias round-trip is what
// breaks if the two ever stop agreeing.
// ---------------------------------------------------------------------------

@autoHydrate
private struct RelAutoDTO {
    int id;
    @field(related: "partner.name") Nullable!string partnerName;
}

// Annotated-only (no @model, no @autoHydrate) — a related: member is still a
// @field, so it counts as an annotated column and case 5 applies.
private struct RelAnnotatedDTO {
    @field                          int    id;
    @field(related: "partner.name") string partnerName;
}

// Every member related: — still an annotated shape.
private struct RelOnlyDTO {
    @field(related: "partner.name") string partnerName;
}

unittest {
    auto c = makeConn();
    auto res = c.exec(`SELECT 7 AS "id", 'Acme' AS "partner_name"`);

    auto a = res.getRow(0).as!RelAutoDTO;
    assert(a.id == 7 && a.partnerName.get == "Acme");

    auto b = res.getRow(0).as!RelAnnotatedDTO;
    assert(b.id == 7 && b.partnerName == "Acme");

    auto d = res.getRow(0).as!RelOnlyDTO;
    assert(d.partnerName == "Acme");
}

unittest {
    // Missing column keeps the usual split: @autoHydrate skips, annotated throws.
    auto c = makeConn();
    auto res = c.exec(`SELECT 7 AS "id"`);

    assert(res.getRow(0).as!RelAutoDTO.partnerName.isNull);
    assertThrown!ColNotExistsError(res.getRow(0).as!RelAnnotatedDTO);
}
