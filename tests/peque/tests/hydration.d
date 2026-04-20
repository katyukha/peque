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
  *  - camelToSnake compile-time utility
  *  - Static assert fires for unannotated structs (via __traits(compiles))
  **/
module peque.tests.hydration;

private import std.process: environment;
private import std.typecons: Nullable, nullable;

private import peque.connection: Connection;
private import peque.result: ResultRow;
private import peque.model: model, field, primaryKey, autoHydrate;
private import peque.hydration: camelToSnake;


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
// camelToSnake — compile-time unit
// ---------------------------------------------------------------------------

unittest {
    static assert(camelToSnake("id")           == "id");
    static assert(camelToSnake("code")         == "code");
    static assert(camelToSnake("emailAddress") == "email_address");
    static assert(camelToSnake("partnerId")    == "partner_id");
    static assert(camelToSnake("createdAt")    == "created_at");
    static assert(camelToSnake("displayName")  == "display_name");
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
