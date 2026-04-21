/** Tests for peque:orm schema SQL generation (schemaSQL / modelDDL).
  *
  * Covers:
  *  - Default type mapping for all supported D types
  *  - @primaryKey → SERIAL / BIGSERIAL
  *  - NOT NULL for non-Nullable fields, absent for Nullable!T fields
  *  - @pgType override (verbatim type, no SERIAL substitution)
  *  - @many2one → REFERENCES target_table(pk_col)
  *  - Nullable @many2one → no NOT NULL before REFERENCES
  *  - schemaSQL!Reg — all models concatenated
  *  - End-to-end: execute generated SQL, insert via ORM, verify round-trip
  **/
module peque.orm.tests.schema;

private import std.process: environment;
private import std.string: indexOf;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, pgType;
private import peque.orm;


// ---------------------------------------------------------------------------
// Test models
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
// modelDDL content assertions
// ---------------------------------------------------------------------------

unittest {
    enum ddl = modelDDL!Author();

    // Table name
    assert(ddl.contains("CREATE TABLE IF NOT EXISTS schema_authors"));

    // @primaryKey int → SERIAL PRIMARY KEY
    assert(ddl.contains("id SERIAL PRIMARY KEY"));

    // string → TEXT NOT NULL
    assert(ddl.contains("name TEXT NOT NULL"));

    // bool → BOOLEAN NOT NULL
    assert(ddl.contains("active BOOLEAN NOT NULL"));

    // long → BIGINT NOT NULL
    assert(ddl.contains("views BIGINT NOT NULL"));

    // Nullable!string → TEXT (no NOT NULL)
    assert(ddl.contains("bio TEXT"));
    assert(!ddl.contains("bio TEXT NOT NULL"));
}

unittest {
    enum ddl = modelDDL!Article();

    assert(ddl.contains("CREATE TABLE IF NOT EXISTS schema_articles"));

    // @primaryKey int → SERIAL PRIMARY KEY
    assert(ddl.contains("id SERIAL PRIMARY KEY"));

    // double → DOUBLE PRECISION NOT NULL
    assert(ddl.contains("rating DOUBLE PRECISION NOT NULL"));

    // camelCase → snake_case
    assert(ddl.contains("word_count INTEGER NOT NULL"));

    // @many2one: non-nullable FK
    assert(ddl.contains("author_id INTEGER NOT NULL REFERENCES schema_authors(id)"));

    // @many2one: Nullable FK — no NOT NULL before REFERENCES
    assert(ddl.contains("editor_id INTEGER REFERENCES schema_authors(id)"));
    assert(!ddl.contains("editor_id INTEGER NOT NULL"));

    // @pgType override: VARCHAR(255) verbatim, not SERIAL
    assert(ddl.contains("status VARCHAR(10) NOT NULL"));
}


// ---------------------------------------------------------------------------
// schemaSQL — all models present in output
// ---------------------------------------------------------------------------

unittest {
    enum sql = schemaSQL!SchemaReg();
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_authors"));
    assert(sql.contains("CREATE TABLE IF NOT EXISTS schema_articles"));
    // Author must appear before Article (FK dependency order)
    assert(sql.indexOf("schema_authors") < sql.indexOf("schema_articles"));
}


// ---------------------------------------------------------------------------
// End-to-end: execute generated SQL, use ORM to insert and query
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
