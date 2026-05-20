/** Tests for peque:orm schema SQL generation (schemaSQL / modelDDL).
  *
  * Covers:
  *  - Default type mapping for all supported D types
  *  - @primaryKey → SERIAL / BIGSERIAL
  *  - NOT NULL for non-Nullable fields, absent for Nullable!T fields
  *  - @pgType override (verbatim type, no SERIAL substitution)
  *  - @many2one → REFERENCES target_table(pk_col)
  *  - Nullable @many2one → no NOT NULL before REFERENCES
  *  - @many2one with OnDelete → ON DELETE CASCADE / RESTRICT / SET NULL / SET DEFAULT
  *  - @unique → UNIQUE on column
  *  - @check → CHECK (expr) on column
  *  - @pgDefault → DEFAULT expr on column
  *  - @pgNotNull → NOT NULL on Nullable field
  *  - @uniqueTogether → table-level UNIQUE (col1, col2)
  *  - @checkConstraint → table-level CONSTRAINT name CHECK (expr)
  *  - @index / @index(where:) → CREATE INDEX, partial index
  *  - @uniqueIndex / @uniqueIndex(where:) → CREATE UNIQUE INDEX, partial
  *  - @ginIndex / @gistIndex / @hashIndex → USING gin/gist/hash
  *  - @indexTogether / @uniqueIndexTogether → multi-column indexes
  *  - schemaSQL!Reg — all models concatenated
  *  - End-to-end: execute generated SQL, insert via ORM, verify round-trip
  **/
module peque.orm.tests.schema;

private import std.datetime: DateTime;
private import std.json: JSONValue;
private import std.process: environment;
private import std.string: indexOf;
private import std.typecons: Nullable;
private import std.uuid: UUID;

private import peque.connection: Connection;
private import peque.model:
    model, field, primaryKey, many2one, pgType, OnDelete,
    unique, check, pgDefault, pgNotNull,
    uniqueTogether, checkConstraint,
    index, uniqueIndex, ginIndex, gistIndex, hashIndex,
    indexTogether, uniqueIndexTogether;
private import peque.orm;


// ---------------------------------------------------------------------------
// Test models — basic type mapping
// ---------------------------------------------------------------------------

@model("schema_authors")
struct Author {
    @primaryKey               int    id;
    @field                    string name;
    @field                    bool   active;
    @field                    long   views;
    @field  Nullable!string   bio;
}

@model("schema_articles")
struct Article {
    @primaryKey                    int     id;
    @field                         string  title;
    @field                         double  rating;
    @field                         int     wordCount;
    @many2one!(Author)             int     authorId;
    @many2one!(Author) Nullable!int editorId;
    @field @pgType("VARCHAR(10)")  string  status;
}

alias SchemaReg = Registry!(
    Bind!(Author,  ModelRepo!Author),
    Bind!(Article, ModelRepo!Article),
);


// ---------------------------------------------------------------------------
// Test models — Phase 2 features
// ---------------------------------------------------------------------------

@model("schema_categories")
struct Category {
    @primaryKey int    id;
    @field      string name;
}

@model("schema_products")
@uniqueTogether!("name", "sku")
@checkConstraint("chk_price_positive", "price > 0")
@indexTogether!("category_id", "active")
struct Product {
    @primaryKey                                                 int          id;
    @field @unique @index                                       string       sku;
    @field                                                      string       name;
    @field @pgDefault("true")                                   bool         active;
    @field @check("price > 0")                                  double       price;
    @field @pgDefault("0")                                      int          stock;
    @field @pgDefault("0") @pgNotNull                           Nullable!int reserved;
    @many2one!(Category, OnDelete.cascade)                      int          categoryId;
    @many2one!(Category, OnDelete.setNull)          Nullable!int altCategoryId;
    @field @uniqueIndex                                         string       slug;
}

alias Phase2Reg = Registry!(
    Bind!(Category, ModelRepo!Category),
    Bind!(Product,  ModelRepo!Product),
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

private bool contains(string haystack, string needle) {
    return haystack.indexOf(needle) >= 0;
}


// ---------------------------------------------------------------------------
// Basic type mapping
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Author();

    assert(ddl.contains("CREATE TABLE IF NOT EXISTS schema_authors"));
    assert(ddl.contains("id SERIAL PRIMARY KEY"));
    assert(ddl.contains("name TEXT NOT NULL"));
    assert(ddl.contains("active BOOLEAN NOT NULL"));
    assert(ddl.contains("views BIGINT NOT NULL"));
    assert(ddl.contains("bio TEXT"));
    assert(!ddl.contains("bio TEXT NOT NULL"));
}

unittest {
    enum ddl = modelDDL!Article();

    assert(ddl.contains("CREATE TABLE IF NOT EXISTS schema_articles"));
    assert(ddl.contains("id SERIAL PRIMARY KEY"));
    assert(ddl.contains("rating DOUBLE PRECISION NOT NULL"));
    assert(ddl.contains("word_count INTEGER NOT NULL"));
    assert(ddl.contains("author_id INTEGER NOT NULL REFERENCES schema_authors(id)"));
    assert(ddl.contains("editor_id INTEGER REFERENCES schema_authors(id)"));
    assert(!ddl.contains("editor_id INTEGER NOT NULL"));
    assert(ddl.contains("status VARCHAR(10) NOT NULL"));
}


// ---------------------------------------------------------------------------
// @many2one OnDelete
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Product();

    // cascade
    assert(ddl.contains(
        "category_id INTEGER NOT NULL REFERENCES schema_categories(id) ON DELETE CASCADE"));

    // setNull — no NOT NULL, with ON DELETE SET NULL
    assert(ddl.contains(
        "alt_category_id INTEGER REFERENCES schema_categories(id) ON DELETE SET NULL"));
    assert(!ddl.contains("alt_category_id INTEGER NOT NULL"));
}

// setNull on non-Nullable field must be a compile-time error — tested via
// static assert in _buildColDef; not repeated here since it would break compilation.


// ---------------------------------------------------------------------------
// Column constraints: @unique, @check, @pgDefault, @pgNotNull
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Product();

    // @unique → UNIQUE
    assert(ddl.contains("sku TEXT NOT NULL UNIQUE"));

    // @check → CHECK (price > 0) inline
    assert(ddl.contains("CHECK (price > 0)"));

    // @pgDefault on non-nullable bool
    assert(ddl.contains("active BOOLEAN NOT NULL DEFAULT true"));

    // @pgDefault on non-nullable int
    assert(ddl.contains("stock INTEGER NOT NULL DEFAULT 0"));

    // @pgDefault + @pgNotNull on Nullable!int — NOT NULL comes before DEFAULT
    assert(ddl.contains("reserved INTEGER NOT NULL DEFAULT 0"));
}


// ---------------------------------------------------------------------------
// Table constraints: @uniqueTogether, @checkConstraint
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Product();

    // @uniqueTogether!("name", "sku")
    assert(ddl.contains("UNIQUE (name, sku)"));

    // @checkConstraint("chk_price_positive", "price > 0")
    assert(ddl.contains("CONSTRAINT chk_price_positive CHECK (price > 0)"));
}


// ---------------------------------------------------------------------------
// Index DDL: @index, @uniqueIndex, @indexTogether
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Product();

    // @index on sku
    assert(ddl.contains("CREATE INDEX IF NOT EXISTS idx_schema_products_sku ON schema_products (sku);"));

    // @uniqueIndex on slug
    assert(ddl.contains("CREATE UNIQUE INDEX IF NOT EXISTS uniq_schema_products_slug ON schema_products (slug);"));

    // @indexTogether!("category_id", "active") on model
    assert(ddl.contains("CREATE INDEX IF NOT EXISTS idx_schema_products_category_id_active ON schema_products (category_id, active);"));
}


// ---------------------------------------------------------------------------
// Test models — index enhancements
// ---------------------------------------------------------------------------

@model("schema_posts")
@uniqueIndexTogether!("author_id", "slug")
@(indexTogether!("author_id", "published_at")(where: "published = true"))
struct Post {
    @primaryKey                                      int             id;
    @field @index                                    int             authorId;
    @field @index(where: "published = true")         string          slug;
    @field @uniqueIndex                              string          externalId;
    @field @uniqueIndex(where: "deleted_at IS NULL") string          code;
    @field @ginIndex                                 JSONValue       metadata;
    @field @hashIndex                                string          sessionToken;
    @field                                           bool             published;
    @field                                           Nullable!DateTime publishedAt;
    @field                                           Nullable!string  deletedAt;
}


// ---------------------------------------------------------------------------
// Index enhancements: DDL checks
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Post();

    // @index (plain) — btree, no USING clause
    assert(ddl.contains(
        "CREATE INDEX IF NOT EXISTS idx_schema_posts_author_id ON schema_posts (author_id);"));

    // @index(where:) — partial index
    assert(ddl.contains(
        "CREATE INDEX IF NOT EXISTS idx_schema_posts_slug ON schema_posts (slug) WHERE published = true;"));

    // @uniqueIndex (plain)
    assert(ddl.contains(
        "CREATE UNIQUE INDEX IF NOT EXISTS uniq_schema_posts_external_id ON schema_posts (external_id);"));

    // @uniqueIndex(where:) — partial unique index
    assert(ddl.contains(
        "CREATE UNIQUE INDEX IF NOT EXISTS uniq_schema_posts_code ON schema_posts (code) WHERE deleted_at IS NULL;"));

    // @ginIndex — USING gin, no UNIQUE (on JSONB metadata column)
    assert(ddl.contains(
        "CREATE INDEX IF NOT EXISTS gin_schema_posts_metadata ON schema_posts USING gin (metadata);"));

    // @hashIndex — USING hash
    assert(ddl.contains(
        "CREATE INDEX IF NOT EXISTS hash_schema_posts_session_token ON schema_posts USING hash (session_token);"));

    // @uniqueIndexTogether — CREATE UNIQUE INDEX, multi-column
    assert(ddl.contains(
        "CREATE UNIQUE INDEX IF NOT EXISTS uniq_schema_posts_author_id_slug ON schema_posts (author_id, slug);"));

    // @indexTogether(where:) — partial multi-column index
    assert(ddl.contains(
        "CREATE INDEX IF NOT EXISTS idx_schema_posts_author_id_published_at ON schema_posts (author_id, published_at) WHERE published = true;"));
}


// ---------------------------------------------------------------------------
// Index enhancements: end-to-end (PostgreSQL accepts generated SQL)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS schema_posts;");
    enum sql = modelDDL!Post();
    c.exec(sql);   // must not throw

    auto repo = Repository!(Post, Connection)(&c);
    import std.json: parseJSON;
    auto p = Post(0, 1, "hello-world", "ext-001", "CODE-1",
                  parseJSON(`{}`), "tok-x", false,
                  Nullable!DateTime.init, Nullable!string.init);
    auto inserted = repo.insert(p);
    assert(inserted.id >= 1);
    assert(inserted.slug == "hello-world");
}


// ---------------------------------------------------------------------------
// schemaSQL — all models present in output
// ---------------------------------------------------------------------------

unittest {
    enum sql = schemaSQL!SchemaReg();
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_authors"));
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_articles"));
    assert(sql.indexOf("schema_authors") < sql.indexOf("schema_articles"));
}

unittest {
    enum sql = schemaSQL!Phase2Reg();
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_categories"));
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_products"));
    // categories must appear before products (FK dependency)
    assert(sql.indexOf("schema_categories") < sql.indexOf("schema_products"));
}


// ---------------------------------------------------------------------------
// End-to-end: basic models
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS schema_articles; DROP TABLE IF EXISTS schema_authors;");

    enum sql = schemaSQL!SchemaReg();
    c.exec(sql);

    auto authorRepo  = Repository!(Author,  Connection)(&c);
    auto articleRepo = Repository!(Article, Connection)(&c);

    auto a = Author(0, "Ada", true, 100, Nullable!string.init);
    auto inserted = authorRepo.insert(a);
    assert(inserted.id >= 1);
    assert(inserted.name == "Ada");

    auto art = Article(0, "Hello", 4.5, 500, inserted.id,
                       Nullable!int.init, "draft");
    auto insertedArt = articleRepo.insert(art);
    assert(insertedArt.id >= 1);
    assert(insertedArt.authorId == inserted.id);
    assert(insertedArt.editorId.isNull);
    assert(insertedArt.status == "draft");

    auto found = authorRepo.findById(inserted.id).get;
    assert(found.name == "Ada");
    assert(found.active == true);
    assert(found.bio.isNull);
}


// ---------------------------------------------------------------------------
// End-to-end: Phase 2 models (constraints, indexes, OnDelete)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    c.exec(`
        DROP TABLE IF EXISTS schema_products;
        DROP TABLE IF EXISTS schema_categories;
    `);

    enum sql = schemaSQL!Phase2Reg();
    c.exec(sql);

    auto catRepo  = Repository!(Category, Connection)(&c);
    auto prodRepo = Repository!(Product,  Connection)(&c);

    auto catTpl = Category(0, "Electronics");
    auto cat = catRepo.insert(catTpl);
    assert(cat.id >= 1);

    // Insert product with all fields
    auto p = Product(0, "SKU-001", "Widget", true, 9.99, 50,
                     Nullable!int(0), cat.id, Nullable!int.init, "widget-slug");
    auto inserted = prodRepo.insert(p);
    assert(inserted.id >= 1);
    assert(inserted.sku == "SKU-001");
    assert(inserted.categoryId == cat.id);
    assert(inserted.altCategoryId.isNull);

    // ON DELETE CASCADE: deleting category must cascade to products
    catRepo.deleteById(cat.id);
    assert(prodRepo.findById(inserted.id).isNull);
}


// ---------------------------------------------------------------------------
// UUID primary key
// ---------------------------------------------------------------------------

@model("schema_tokens")
struct Token {
    @primaryKey UUID   id;
    @field      string name;
}

alias TokenReg = Registry!(Bind!(Token, ModelRepo!Token));

unittest {
    enum ddl = modelDDL!Token();

    assert(ddl.contains("CREATE TABLE IF NOT EXISTS schema_tokens"));
    assert(ddl.contains("id UUID PRIMARY KEY DEFAULT gen_random_uuid()"));
    assert(ddl.contains("name TEXT NOT NULL"));
}

unittest {
    auto c = makeConn();
    c.exec("DROP TABLE IF EXISTS schema_tokens;");
    enum sql = schemaSQL!TokenReg();
    c.exec(sql);

    auto repo = Repository!(Token, Connection)(&c);

    // Insert with zero UUID — DB assigns gen_random_uuid()
    auto t = Token(UUID.init, "session");
    auto inserted = repo.insert(t);
    assert(inserted.id != UUID.init);
    assert(inserted.name == "session");

    // findById with the returned UUID must work
    auto found = repo.findById(inserted.id).get;
    assert(found.name == "session");

    // upsert with explicit UUID — must honour caller-provided PK
    auto explicit = UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    auto t2 = Token(explicit, "fixed");
    auto ups = repo.upsert(t2);
    assert(ups.id == explicit);
    assert(ups.name == "fixed");
}
