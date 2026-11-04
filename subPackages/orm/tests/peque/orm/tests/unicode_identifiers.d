/** Non-ASCII identifiers end to end: a model whose table and columns are
  * Cyrillic, through DDL and index names, insert and hydration, `load!`'s
  * joined-column aliases, `select!DTO`, `orderBy` in every form and
  * `@defaultOrder`.
  *
  * PostgreSQL treats every byte above 0x7F as an identifier character and,
  * under a multibyte encoding, folds only ASCII letters, so an unquoted
  * Cyrillic name is legal and keeps its case. peque follows the same two
  * rules wherever a name is emitted bare.
  **/
module peque.orm.tests.unicode_identifiers;

private import std.algorithm.searching: canFind, count;
private import std.process: environment;
private import std.typecons: Nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related, defaultOrder, autoHydrate;
private import peque.orm;


private Connection makeConn() {
    return Connection(
        dbname:   environment.get("POSTGRES_DB",       "peque-test"),
        user:     environment.get("POSTGRES_USER",     "peque"),
        password: environment.get("POSTGRES_PASSWORD", "peque"),
        host:     environment.get("POSTGRES_HOST",     "localhost"),
        port:     environment.get("POSTGRES_PORT",     "5432"),
    );
}

@model("ui_країна")
struct Країна {
    @primaryKey int id;
    @field @index string назва;
    @field @index string код;
}

@model("ui_місто")
@defaultOrder!("назва DESC")
struct Місто {
    @primaryKey int id;
    @field("назва") string name;
    @field          int    населення;   // a bare member: mapped as written
    @many2one!(Країна) int країнаId;
    @related("країнаId") Nullable!Країна країна;
}

@autoHydrate
struct МістоDTO { string назва; int населення; }

alias UiReg = Registry!(Bind!(Країна, ModelRepo!Країна), Bind!(Місто, ModelRepo!Місто));

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS "ui_місто"; DROP TABLE IF EXISTS "ui_країна";`);
    enum ddl = schemaSQL!UiReg();
    // Two indexed Cyrillic columns must get two different index names, or the
    // second CREATE INDEX IF NOT EXISTS silently creates nothing.
    assert(ddl.count("CREATE INDEX IF NOT EXISTS") == 2, ddl);
    assert(ddl.canFind("idx_ui_країна_назва") && ddl.canFind("idx_ui_країна_код"), ddl);
    c.exec(ddl);
    assert(c.exec(`SELECT count(*) FROM pg_indexes WHERE tablename = 'ui_країна' AND indexname LIKE 'idx_%'`)
            .getValue!long(0, 0) == 2, "both indexes exist on the server");

    auto країни = Repository!(Країна, Connection)(&c);
    auto міста  = Repository!(Місто,  Connection)(&c);
    Країна ua; ua.назва = "Україна"; ua.код = "UA"; auto saved = країни.insert(ua);
    foreach (name, pop; ["Київ": 2_900_000, "Львів": 720_000, "Одеса": 1_000_000]) {
        Місто m; m.name = name; m.населення = pop; m.країнаId = saved.id;
        міста.insert(m);
    }

    // Hydration and @defaultOrder (a bare Cyrillic column, unquoted).
    auto all = міста.query().all();
    assert(all.length == 3 && all[0].name == "Одеса" && all[2].name == "Київ");

    // load!: the joined model's two Cyrillic columns must land in their own
    // fields, not in whichever alias happened to win.
    auto loaded = міста.query().load!"країна".orderBy!"name".all();
    assert(loaded[0].країна.get.назва == "Україна" && loaded[0].країна.get.код == "UA");

    // orderBy in every form.
    assert(міста.query().orderBy("населення").all()[0].name == "Львів");
    assert(міста.query().orderBy(`"назва"`).all()[0].name == "Київ");
    assert(міста.query().orderBy("назва ASC, населення DESC").all()[0].name == "Київ");
    assert(міста.query().orderBy!"-населення".all()[0].name == "Київ");
    assert(міста.query().orderBy(F!(Місто, "населення").desc).all()[0].name == "Київ");
    assert(міста.query().load!"країна".orderBy("назва").all()[0].name == "Київ",
        "a bare name is qualified, so the joined table's назва does not make it ambiguous");

    // select!DTO with Cyrillic members.
    auto dtos = міста.query().orderBy("назва").select!МістоDTO();
    assert(dtos.length == 3 && dtos[0].назва == "Київ" && dtos[0].населення == 2_900_000);

    c.exec(`DROP TABLE IF EXISTS "ui_місто"; DROP TABLE IF EXISTS "ui_країна";`);
}
