/** Integration tests for QuerySet.asSubquery + F.inSubquery.
  *
  * Covers:
  *  - asSubquery!"field"() — produces SubQuery!T without hitting the DB
  *  - F!(M,"f").inSubquery(sub) — membership in the subquery's set
  *  - ~F!(M,"f").inSubquery(sub) — its exact complement, NULLs included
  *  - asSubquery with WHERE filter on the inner query
  *  - asSubquery with LIMIT on the inner query
  *  - empty inner result → zero outer rows (not a SQL error)
  *  - param renumbering when the outer query also has bound params
  *  - type-free F!"field".inSubquery(sub) (FieldBuilder path)
  *  - NULL on either side: p and ~p still split the rows exactly
  **/
module peque.orm.tests.assubquery;

private import std.process: environment;
private import std.algorithm: sort;
private import std.array: array;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models — category + product, the classic one-to-many
// ---------------------------------------------------------------------------

@model("sq_categories")
struct SqCategory {
    @primaryKey int    id;
    @field      string name;
    @field      bool   active;
}

@model("sq_products")
struct SqProduct {
    @primaryKey int    id;
    @field      string name;
    @field      int    categoryId;
    @field      int    price;
}

alias SqReg = Registry!(
    Bind!(SqCategory, ModelRepo!SqCategory),
    Bind!(SqProduct,  ModelRepo!SqProduct),
);

private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

private void createTables(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS sq_products;");
    c.exec("DROP TABLE IF EXISTS sq_categories;");
    c.exec(schemaSQL!SqReg());
}

// Returns (categories, products) after seeding:
//   categories: Electronics(active), Books(active), Archived(inactive)
//   products:   each category gets two products
private void seed(ref Connection c,
    out SqCategory[] cats, out SqProduct[] prods)
{
    auto cr = Repository!(SqCategory, Connection)(&c);
    auto pr = Repository!(SqProduct,  Connection)(&c);

    auto electronics = SqCategory(0, "Electronics", true);
    auto books       = SqCategory(0, "Books",       true);
    auto archived    = SqCategory(0, "Archived",    false);
    cats = [cr.insert(electronics), cr.insert(books), cr.insert(archived)];

    foreach (ref cat; cats) {
        auto p1 = SqProduct(0, cat.name ~ "-A", cat.id, 10);
        auto p2 = SqProduct(0, cat.name ~ "-B", cat.id, 20);
        prods ~= [pr.insert(p1), pr.insert(p2)];
    }
}


// ---------------------------------------------------------------------------
// Basic IN — products whose category is active
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    auto activeCatIds = catRepo.query()
        .where!"active"(true)
        .asSubquery!"id"();

    auto products = prodRepo.query()
        .where(F!(SqProduct, "categoryId").inSubquery(activeCatIds))
        .all();

    assert(products.length == 4);  // Electronics-A/B + Books-A/B
    foreach (ref p; products)
        assert(p.categoryId != cats[2].id,  "Archived products must be excluded");
}


// ---------------------------------------------------------------------------
// NOT IN — products in the inactive category only
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    auto activeCatIds = catRepo.query()
        .where!"active"(true)
        .asSubquery!"id"();

    auto rest = prodRepo.query()
        .where(~F!(SqProduct, "categoryId").inSubquery(activeCatIds))
        .all();

    assert(rest.length == 2);  // Archived-A + Archived-B
    foreach (ref p; rest)
        assert(p.categoryId == cats[2].id);
}


// ---------------------------------------------------------------------------
// Empty inner result → zero outer rows (no SQL error)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    // No categories match this filter → subquery returns zero rows
    auto noIds = catRepo.query()
        .where!"name"("DoesNotExist")
        .asSubquery!"id"();

    auto products = prodRepo.query()
        .where(F!(SqProduct, "categoryId").inSubquery(noIds))
        .all();
    assert(products.length == 0);
}


// ---------------------------------------------------------------------------
// Outer query also has bound params — renumbering must not collide
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    auto activeCatIds = catRepo.query()
        .where!"active"(true)
        .asSubquery!"id"();

    // outer WHERE has its own param (price > $1), subquery adds another
    auto products = prodRepo.query()
        .where(F!(SqProduct, "categoryId").inSubquery(activeCatIds))
        .where(F!(SqProduct, "price").gt(15))
        .all();

    // Only -B products (price=20) in active categories
    assert(products.length == 2);
    foreach (ref p; products)
        assert(p.price == 20);
}


// ---------------------------------------------------------------------------
// asSubquery with LIMIT on the inner query
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    // Only take one active category ID
    auto oneCatId = catRepo.query()
        .where!"active"(true)
        .orderBy("id ASC")
        .limit(1)
        .asSubquery!"id"();

    auto products = prodRepo.query()
        .where(F!(SqProduct, "categoryId").inSubquery(oneCatId))
        .all();

    assert(products.length == 2);  // only the first active category's products
    foreach (ref p; products)
        assert(p.categoryId == cats[0].id);
}


// ---------------------------------------------------------------------------
// Two-level nesting — verifies _shiftParams applies recursively
//
// sub1: category IDs where name LIKE 'E%'          param $1 = "E%"
// sub2: product IDs in those categories, price>15  embeds sub1 ($1), adds $2=15
// outer: products whose id IN sub2, price<25       adds outer $1=25 → shifts sub2's
//        $1→$2 and $2→$3                           (if shift breaks: type error or
//                                                   wrong rows)
//
// Expected: exactly Electronics-B (price=20, in Electronics category)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    // Level 1 — categories whose name starts with 'E'
    auto electronicsCatIds = catRepo.query()
        .where(F!(SqCategory, "name").like("E%"))
        .asSubquery!"id"();          // SubQuery!int; sql has $1 = "E%"

    // Level 2 — products in those categories, price > 15; embeds level 1
    auto expensiveElectronicsIds = prodRepo.query()
        .where(F!(SqProduct, "categoryId").inSubquery(electronicsCatIds))
        .where(F!(SqProduct, "price").gt(15))
        .asSubquery!"id"();          // SubQuery!int; sql has $1="E%" and $2=15

    // Outer — products whose own id is in level-2 set, AND price < 25
    // The outer "price < $1" (val=25) is bound first; the inSubquery shifts
    // level-2's $1→$2 and $2→$3, so final params = [25, "E%", 15].
    auto result = prodRepo.query()
        .where(F!(SqProduct, "price").lt(25))
        .where(F!(SqProduct, "id").inSubquery(expensiveElectronicsIds))
        .all();

    assert(result.length == 1);
    assert(result[0].name == "Electronics-B");
    assert(result[0].price == 20);
}


// ---------------------------------------------------------------------------
// Type-free F!"field".inSubquery — FieldBuilder path (no dot)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    createTables(c);
    SqCategory[] cats;
    SqProduct[]  prods;
    seed(c, cats, prods);

    auto catRepo  = Repository!(SqCategory, Connection)(&c);
    auto prodRepo = Repository!(SqProduct,  Connection)(&c);

    auto activeCatIds = catRepo.query()
        .where!"active"(true)
        .asSubquery!"id"();

    // F!"categoryId" converts to the category_id column
    auto products = prodRepo.query()
        .where(F!"categoryId".inSubquery(activeCatIds))
        .all();

    assert(products.length == 4);
}



// ---------------------------------------------------------------------------
// NULL on either side: p and ~p split the rows exactly
// ---------------------------------------------------------------------------

// SQL's `col IN (sub)` is UNKNOWN for a non-member once the subquery yields a
// NULL, so `NOT IN` matches nothing, and a NULL col is in neither. peque's
// membership is two-valued: a NULL is simply not in the set, so p and ~p
// partition the rows.

@model("sq_nl_owners")
struct SqNlOwner {
    @primaryKey int    id;
    @field      string name;
}

@model("sq_nl_items")
struct SqNlItem {
    @primaryKey int          id;
    @field      string       name;
    @field      Nullable!int ownerId;
}

alias SqNlReg = Registry!(
    Bind!(SqNlOwner, ModelRepo!SqNlOwner),
    Bind!(SqNlItem,  ModelRepo!SqNlItem),
);

unittest {
    import std.algorithm.iteration: map;

    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS sq_nl_items;");
    c.exec("DROP TABLE IF EXISTS sq_nl_owners;");
    c.exec(schemaSQL!SqNlReg());
    // Owners a, b, c; items: two owned by a, one orphan with a NULL owner.
    c.exec(`INSERT INTO sq_nl_owners (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')`);
    c.exec(`INSERT INTO sq_nl_items (id, name, owner_id)
            VALUES (1, 'i1', 1), (2, 'i2', 1), (3, 'orphan', NULL)`);

    auto owners = Repository!(SqNlOwner, Connection)(&c);
    auto items  = Repository!(SqNlItem,  Connection)(&c);
    string[] names(R)(R rows) { return rows.map!(r => r.name).array.sort.array; }

    // A NULL in the set: "owners with no items" must not come back empty.
    auto ownedIds = items.query().asSubquery!"ownerId"();
    auto owned    = F!(SqNlOwner, "id").inSubquery(ownedIds);
    assert(names(owners.query().where(owned).all())  == ["a"]);
    assert(names(owners.query().where(~owned).all()) == ["b", "c"]);
    // ... nor inside a compound predicate, where UNKNOWN would spread.
    assert(names(owners.query().where(~(F!(SqNlOwner, "name").ne("z") & owned)).all())
           == ["b", "c"]);

    // A NULL in the row's own column: the orphan is not in a's set.
    auto aIds = owners.query().where!"name"("a").asSubquery!"id"();
    auto ofA  = F!(SqNlItem, "ownerId").inSubquery(aIds);
    assert(names(items.query().where(ofA).all())  == ["i1", "i2"]);
    assert(names(items.query().where(~ofA).all()) == ["orphan"]);

    // An empty set: nothing is in it, everything is outside it.
    auto noIds = owners.query().none().asSubquery!"id"();
    assert(items.query().where(F!(SqNlItem, "ownerId").inSubquery(noIds)).count() == 0);
    assert(items.query().where(~F!(SqNlItem, "ownerId").inSubquery(noIds)).count() == 3);
}
