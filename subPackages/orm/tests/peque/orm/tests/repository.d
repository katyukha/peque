/** Integration tests for peque:orm Phase 4b — Repository + CRUDMixin.
  *
  * Covers:
  *  - Repository!(M, Connection) for all five CRUD operations
  *  - CRUDMixin in a user-defined struct with an extra custom method
  *  - @many2one field included in SELECT / INSERT / UPDATE
  *  - findById returns Nullable.init for missing rows
  *  - insert returns the row with the generated PK (RETURNING)
  *  - isModel compile-time constraint rejects unannotated structs
  **/
module peque.orm.tests.repository;

private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("peque_orm_items")
struct Item {
    @primaryKey int    id;
    @field      string code;
    @field      string name;
    @field      int    score;
}

// Model with an explicit @field column-name override
@model("peque_orm_items")
struct ItemAlias {
    @primaryKey             int    id;
    @field("code")          string itemCode;   // explicit override
    @field                  string name;
    @field                  int    score;
}

// Models for @many2one relation test
@model("peque_orm_categories")
struct Category {
    @primaryKey int    id;
    @field      string name;
}

@model("peque_orm_products")
struct Product {
    @primaryKey          int    id;
    @field               string name;
    @many2one!(Category) int    categoryId;   // DB column: category_id
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

private void setupItems(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS peque_orm_items;
        CREATE TABLE peque_orm_items (
            id    serial PRIMARY KEY,
            code  varchar(10) NOT NULL,
            name  varchar(40) NOT NULL,
            score int NOT NULL DEFAULT 0
        );
        INSERT INTO peque_orm_items (code, name, score)
        VALUES ('a1', 'Alpha', 10),
               ('b2', 'Beta',  20),
               ('c3', 'Gamma', 30);
    `);
}

private void setupRelations(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS peque_orm_products;
        DROP TABLE IF EXISTS peque_orm_categories;
        CREATE TABLE peque_orm_categories (
            id   serial PRIMARY KEY,
            name varchar(40) NOT NULL
        );
        CREATE TABLE peque_orm_products (
            id          serial PRIMARY KEY,
            name        varchar(40) NOT NULL,
            category_id int REFERENCES peque_orm_categories(id)
        );
        INSERT INTO peque_orm_categories (name) VALUES ('Electronics'), ('Books');
        INSERT INTO peque_orm_products (name, category_id)
        SELECT 'Laptop', id FROM peque_orm_categories WHERE name = 'Electronics';
        INSERT INTO peque_orm_products (name, category_id)
        SELECT 'Novel',  id FROM peque_orm_categories WHERE name = 'Books';
    `);
}


// ---------------------------------------------------------------------------
// findAll
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    setupItems(c);
    auto repo  = Repository!(Item, Connection)(&c);
    auto items = repo.findAll();
    assert(items.length == 3);
    assert(items[0].code == "a1");
    assert(items[1].code == "b2");
    assert(items[2].code == "c3");
}


// ---------------------------------------------------------------------------
// findById — found and not found
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo  = Repository!(Item, Connection)(&c);
    auto all   = repo.findAll();
    auto found = repo.findById(all[0].id);
    assert(!found.isNull);
    assert(found.get.code == "a1");
    assert(found.get.score == 10);
}

unittest {
    auto c        = makeConn();
    setupItems(c);
    auto repo     = Repository!(Item, Connection)(&c);
    auto notFound = repo.findById(-1);
    assert(notFound.isNull);
}


// ---------------------------------------------------------------------------
// insert — RETURNING populates the generated PK
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo = Repository!(Item, Connection)(&c);
    auto tpl  = Item(0, "z9", "Zeta", 99);
    auto ins  = repo.insert(tpl);

    assert(ins.id  >= 1);
    assert(ins.code  == "z9");
    assert(ins.name  == "Zeta");
    assert(ins.score == 99);

    // Verify row was actually written
    auto reloaded = repo.findById(ins.id);
    assert(!reloaded.isNull);
    assert(reloaded.get.code == "z9");
}


// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo = Repository!(Item, Connection)(&c);
    auto all  = repo.findAll();
    auto item = all[0];

    item.name  = "Updated";
    item.score = 999;
    repo.update(item);

    auto got = repo.findById(item.id).get;
    assert(got.name  == "Updated");
    assert(got.score == 999);
    assert(got.code  == "a1");   // untouched field preserved
}


// ---------------------------------------------------------------------------
// deleteById
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo = Repository!(Item, Connection)(&c);
    auto all  = repo.findAll();
    auto id   = all[0].id;

    repo.deleteById(id);

    auto remaining = repo.findAll();
    assert(remaining.length == 2);
    assert(repo.findById(id).isNull);
}


// ---------------------------------------------------------------------------
// Explicit @field column-name override in SELECT / INSERT / UPDATE
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo = Repository!(ItemAlias, Connection)(&c);
    auto all  = repo.findAll();
    // itemCode maps to DB column "code" via @field("code")
    assert(all[0].itemCode == "a1");
    assert(all[1].itemCode == "b2");
}


// ---------------------------------------------------------------------------
// CRUDMixin in user-defined struct + custom method
// ---------------------------------------------------------------------------

struct ItemRepository {
    private Connection* _ctx;
    mixin CRUDMixin!(Item, Connection);

    Item[] findByMinScore(int minScore) {
        import peque.orm.sql: buildSelectList, ormTableName;
        return _ctx.execParams(
            "SELECT " ~ buildSelectList!Item() ~ " FROM " ~ ormTableName!Item ~
            " WHERE score >= $1 ORDER BY score",
            minScore).as!(Item[]);
    }
}

unittest {
    auto c    = makeConn();
    setupItems(c);
    auto repo = ItemRepository(&c);

    auto all = repo.findAll();
    assert(all.length == 3);

    auto filtered = repo.findByMinScore(20);
    assert(filtered.length == 2);
    assert(filtered[0].code == "b2");
    assert(filtered[1].code == "c3");
}


// ---------------------------------------------------------------------------
// @many2one field is a DB column — included in SELECT, INSERT, UPDATE
// ---------------------------------------------------------------------------

unittest {
    auto c    = makeConn();
    setupRelations(c);
    auto repo = Repository!(Product, Connection)(&c);

    auto products = repo.findAll();
    assert(products.length == 2);
    // categoryId (→ category_id) is hydrated from the FK column
    assert(products[0].categoryId >= 1);
    assert(products[1].categoryId >= 1);
    assert(products[0].categoryId != products[1].categoryId);
}

unittest {
    auto c       = makeConn();
    setupRelations(c);
    auto catRepo = Repository!(Category, Connection)(&c);
    auto prodRepo = Repository!(Product, Connection)(&c);

    auto cats = catRepo.findAll();
    assert(cats.length == 2);

    // insert a product with a specific categoryId (many2one FK)
    auto tpl = Product(0, "Keyboard", cats[0].id);
    auto ins = prodRepo.insert(tpl);
    assert(ins.id >= 1);
    assert(ins.name == "Keyboard");
    assert(ins.categoryId == cats[0].id);

    // update the FK to point at the other category
    ins.categoryId = cats[1].id;
    prodRepo.update(ins);

    auto reloaded = prodRepo.findById(ins.id).get;
    assert(reloaded.categoryId == cats[1].id);
}


// ---------------------------------------------------------------------------
// isModel compile-time constraint rejects unannotated struct
// ---------------------------------------------------------------------------

private struct Bare { int id; string name; }

unittest {
    static assert( isModel!Item);
    static assert( isModel!Product);
    static assert(!isModel!Bare);
}
