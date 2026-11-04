/** The write side of @many2many: `links!"rel"(id)` and the junction DDL.
  *
  * Pins, against a real database: add, remove, clear and set, and `within`
  * bounding all four; the honest diff set returns; `Nullable!(T[])` telling "never prefetched" from "no rows"; both
  * UDA forms, including a self-referential junction model; reserved-word
  * junction names; rollback inside a transaction; a wrong junction column
  * failing as QueryServerError; and what schemaSQL emits for managed, external
  * and twice-declared junctions. Compile-time rejections close the file.
  **/
module peque.orm.tests.many2many_write;

private import std.algorithm.sorting: sort;
private import std.algorithm.searching: count;
private import std.exception: assertThrown;
private import std.process: environment;
private import std.string: indexOf;
private import std.typecons: Nullable;

private import peque.connection: Connection, Transaction;
private import peque.exception: QueryServerError;
private import peque.model: model, field, primaryKey, many2one, many2many,
    Junction, uniqueTogether, indexTogether, OnDelete;
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

private int[] sorted(int[] a) { sort(a); return a; }


// ===========================================================================
// Models
// ===========================================================================

// String form, managed, declared from BOTH sides over one junction. The field
// on MwDoc is Nullable so a never-prefetched relation is distinguishable.
@model("mw_tag")
struct MwTag {
    @primaryKey int    id;
    @field      string name;
    @many2many!(MwDoc, "mw_doc_tag", "tag_id", "doc_id") MwDoc[] docs;
}

@model("mw_doc")
struct MwDoc {
    @primaryKey int    id;
    @field      string title;
    @many2many!(MwTag, "mw_doc_tag", "doc_id", "tag_id") Nullable!(MwTag[]) tags;
}

// Model form: keys inferred from the junction's two @many2one fields.
@model("mw_perm")
struct MwPerm {
    @primaryKey int    id;
    @field      string code;
}

@model("mw_group_perm")
@uniqueTogether!("groupId", "permId")
@indexTogether!("permId", "groupId")
struct MwGroupPerm {
    @primaryKey                            int id;
    @many2one!(MwGroup, OnDelete.cascade)  int groupId;
    @many2one!(MwPerm,  OnDelete.cascade)  int permId;
}

@model("mw_group")
struct MwGroup {
    @primaryKey int    id;
    @field      string name;
    @many2many!(MwPerm, MwGroupPerm) MwPerm[] perms;
}

// Model form, self-referential: both FKs hit mw_node, so the keys are named.
@model("mw_node")
struct MwNode {
    @primaryKey int    id;
    @field      string label;
    @many2many!(MwNode, MwEdge, "fromId", "toId") MwNode[] next;
}

@model("mw_edge")
@uniqueTogether!("fromId", "toId")
struct MwEdge {
    @primaryKey                            int id;
    @many2one!(MwNode, OnDelete.cascade)   int fromId;
    @many2one!(MwNode, OnDelete.cascade)   int toId;
}

// Reserved words everywhere a junction name is emitted.
@model("mw_order")
struct MwOrder {
    @primaryKey int    id;
    @field      string code;
    @many2many!(MwTag, "window", "order", "desc") MwTag[] tags;
}

alias MwReg = Registry!(
    Bind!(MwTag,       ModelRepo!MwTag),
    Bind!(MwDoc,       ModelRepo!MwDoc),
    Bind!(MwPerm,      ModelRepo!MwPerm),
    Bind!(MwGroup,     ModelRepo!MwGroup),
    Bind!(MwGroupPerm, ModelRepo!MwGroupPerm),
    Bind!(MwNode,      ModelRepo!MwNode),
    Bind!(MwEdge,      ModelRepo!MwEdge),
    Bind!(MwOrder,     ModelRepo!MwOrder),
);

private void resetSchema(ref Connection c) {
    c.exec(`
        DROP TABLE IF EXISTS "window";
        DROP TABLE IF EXISTS mw_doc_tag;
        DROP TABLE IF EXISTS mw_edge;
        DROP TABLE IF EXISTS mw_group_perm;
        DROP TABLE IF EXISTS mw_order;
        DROP TABLE IF EXISTS mw_node;
        DROP TABLE IF EXISTS mw_group;
        DROP TABLE IF EXISTS mw_perm;
        DROP TABLE IF EXISTS mw_doc;
        DROP TABLE IF EXISTS mw_tag;
    `);
    c.exec(schemaSQL!MwReg());
}

// Repositories borrow &c, so they are built on demand against the test's own
// local rather than stored in a struct that is returned by value.
private struct Fixture {
    Connection c;
    MwDoc a, b;
    int red, green, blue, black;   // tag ids

    auto docs() { return Repository!(MwDoc, Connection)(&c); }
    auto tags() { return Repository!(MwTag, Connection)(&c); }
}

private Fixture fixture() {
    Fixture f;
    f.c = makeConn();
    resetSchema(f.c);
    MwDoc a; a.title = "A"; f.a = f.docs.insert(a);
    MwDoc b; b.title = "B"; f.b = f.docs.insert(b);
    foreach (name, id; ["red": &f.red, "green": &f.green, "blue": &f.blue, "black": &f.black]) {
        MwTag t; t.name = name;
        *id = f.tags.insert(t).id;
    }
    return f;
}

private int[] linksOf(ref Connection c, int docId) {
    int[] r;
    foreach (row; c.execParams(`SELECT tag_id FROM mw_doc_tag WHERE doc_id = $1`, docId))
        r ~= row[0].as!int;
    return sorted(r);
}


// ===========================================================================
// schemaSQL: managed junction DDL
// ===========================================================================

unittest {
    enum sql = schemaSQL!MwReg();

    // Declared from both sides, emitted once, with the first side's column order.
    assert(sql.count(`CREATE TABLE IF NOT EXISTS "mw_doc_tag"`) == 1, sql);
    enum jt = sql[sql.indexOf(`CREATE TABLE IF NOT EXISTS "mw_doc_tag"`) .. $];
    assert(jt.indexOf(`"tag_id" INTEGER NOT NULL REFERENCES "mw_tag"("id") ON DELETE CASCADE`) >= 0, jt);
    assert(jt.indexOf(`"doc_id" INTEGER NOT NULL REFERENCES "mw_doc"("id") ON DELETE CASCADE`) >= 0, jt);
    assert(jt.indexOf(`PRIMARY KEY ("tag_id", "doc_id")`) >= 0, jt);
    assert(jt.indexOf(`CREATE INDEX IF NOT EXISTS idx_mw_doc_tag_doc_id_tag_id ON "mw_doc_tag" ("doc_id", "tag_id")`) >= 0, jt);

    // A junction model is emitted as a model, never a second time as a junction.
    assert(sql.count(`CREATE TABLE IF NOT EXISTS "mw_group_perm"`) == 1, sql);
    assert(sql.indexOf(`PRIMARY KEY ("group_id"`) < 0, sql);

    // Junctions come after every model table, so their REFERENCES resolve.
    assert(sql.indexOf(`"mw_doc_tag"`) > sql.indexOf(`"mw_order"`), sql);

    // Reserved-word names are quoted throughout.
    assert(sql.indexOf(`CREATE TABLE IF NOT EXISTS "window" (`) >= 0, sql);
    assert(sql.indexOf(`PRIMARY KEY ("order", "desc")`) >= 0, sql);
    assert(sql.indexOf(`idx_window_desc_order ON "window" ("desc", "order")`) >= 0, sql);
}

// Junction.external: nothing emitted for it.
@model("mw_ext_doc")
struct MwExtDoc {
    @primaryKey int id;
    @many2many!(MwTag, "mw_ext_doc_tag", "doc_id", "tag_id", Junction.external) MwTag[] tags;
}
unittest {
    enum sql = schemaSQL!(Registry!(Bind!(MwExtDoc, ModelRepo!MwExtDoc)))();
    assert(sql.indexOf("mw_ext_doc_tag") < 0, sql);
    assert(sql.count("CREATE TABLE") == 1, sql);
}


// ===========================================================================
// Nullable!(T[]): null until prefetched, empty after when there are no rows
// ===========================================================================

unittest {
    auto f = fixture();
    f.docs.links!"tags"(f.a.id).add([f.red]);

    auto plain = f.docs.query().orderBy!"title".all();
    assert(plain[0].tags.isNull && plain[1].tags.isNull, "nobody prefetched");

    auto loaded = f.docs.query().orderBy!"title".prefetch!"tags".all();
    assert(!loaded[0].tags.isNull && loaded[0].tags.get.length == 1);
    assert(!loaded[1].tags.isNull && loaded[1].tags.get.length == 0,
        "prefetched with no rows is empty, not null");

    // The other side, declared as a plain array, is unchanged.
    auto tags = f.tags.query().where!"id"(f.red).prefetch!"docs".all();
    assert(tags.length == 1 && tags[0].docs.length == 1 && tags[0].docs[0].title == "A");
}


// ===========================================================================
// add / remove / clear
// ===========================================================================

unittest {
    auto f = fixture();
    auto la = f.docs.links!"tags"(f.a.id);
    f.docs.links!"tags"(f.b.id).add([f.red, f.blue]);   // another parent's links

    const(int)[] rg = [f.red, f.green];          // what a form handler holds
    assert(la.add(rg) == 2);
    assert(la.add(rg) == 0, "already linked: nothing inserted");
    assert(la.add([f.green, f.green, f.blue, 999_999]) == 1,
        "duplicate once, unknown id ignored");
    assert(la.add([]) == 0);
    assert(linksOf(f.c, f.a.id) == sorted([f.red, f.green, f.blue]));

    assert(la.remove([f.green, 999_999]) == 1);
    assert(la.remove([f.green]) == 0);
    assert(la.remove([]) == 0);
    assert(linksOf(f.c, f.a.id) == sorted([f.red, f.blue]));

    assert(la.clear() == 2);
    assert(la.clear() == 0);
    assert(linksOf(f.c, f.a.id).length == 0);

    assert(linksOf(f.c, f.b.id) == sorted([f.red, f.blue]), "B was never touched");
}

// Subquery inputs, carrying their own parameters.
unittest {
    auto f = fixture();
    auto la = f.docs.links!"tags"(f.a.id);
    auto rg = f.tags.query().whereIn!"name"(["red", "green"]).asSubquery!"id"();

    assert(la.add(rg) == 2);
    assert(la.add(rg) == 0);
    assert(linksOf(f.c, f.a.id) == sorted([f.red, f.green]));
    assert(la.remove(f.tags.query().where!"name"("red").asSubquery!"id"()) == 1);
    assert(linksOf(f.c, f.a.id) == [f.green]);
}


// ===========================================================================
// set: the honest diff
// ===========================================================================

unittest {
    auto f = fixture();
    auto la = f.docs.links!"tags"(f.a.id);
    f.docs.links!"tags"(f.b.id).add([f.red, f.blue]);

    const(int)[] rg = [f.red, f.green];
    auto c1 = la.set(rg);
    assert(sorted(c1.added) == sorted([f.red, f.green]) && c1.removed.length == 0 && c1.changed);

    // red kept (reported in neither), green removed, blue added; unknown
    // ignored; duplicate once.
    auto c2 = la.set([f.red, f.blue, f.blue, 999_999]);
    assert(c2.added == [f.blue], "only the row really inserted");
    assert(c2.removed == [f.green], "only the row really deleted");
    assert(linksOf(f.c, f.a.id) == sorted([f.red, f.blue]));

    auto c3 = la.set([f.red, f.blue]);
    assert(!c3.changed && c3.added.length == 0 && c3.removed.length == 0,
        "a repeat call changes nothing and reports nothing");

    auto c4 = la.set([]);
    assert(sorted(c4.removed) == sorted([f.red, f.blue]) && c4.added.length == 0);
    assert(linksOf(f.c, f.a.id).length == 0);

    // An unknown parent is a no-op with an empty change — not an error.
    auto c5 = f.docs.links!"tags"(999_999).set([f.red]);
    assert(!c5.changed);
    assert(f.c.exec(`SELECT count(*) FROM mw_doc_tag`)[0][0].as!long == 2);

    assert(linksOf(f.c, f.b.id) == sorted([f.red, f.blue]), "B was never touched");
}


// ===========================================================================
// within: the universe bounds every operation, removal included
// ===========================================================================

unittest {
    auto f = fixture();
    auto la = f.docs.links!"tags"(f.a.id);
    la.add([f.black]);                       // a link outside the universe

    // Two parameters of its own, so the writer's $N shifting is exercised.
    auto colours = f.tags.query()
        .whereIn!"name"(["red", "green", "blue"])
        .where(~F!(MwTag, "name")("black"))
        .asSubquery!"id"();
    auto bounded = la.within(colours);

    assert(bounded.add([f.red, f.black]) == 1, "black is outside: ignored");
    assert(linksOf(f.c, f.a.id) == sorted([f.red, f.black]));

    // Not in ids, but outside the universe: black stays.
    auto c1 = bounded.set([f.green]);
    assert(c1.added == [f.green] && c1.removed == [f.red]);
    assert(linksOf(f.c, f.a.id) == sorted([f.green, f.black]));

    assert(bounded.remove([f.green, f.black]) == 1);
    assert(linksOf(f.c, f.a.id) == [f.black]);

    bounded.add([f.red, f.blue]);
    assert(bounded.set([]).removed.length == 2);
    assert(linksOf(f.c, f.a.id) == [f.black], "set([]) empties the universe only");

    bounded.add([f.red]);
    assert(bounded.clear() == 1);
    assert(linksOf(f.c, f.a.id) == [f.black], "clear empties the universe only");

    // A subquery universe and a subquery input, each with parameters.
    assert(bounded.add(f.tags.query().whereIn!"name"(["blue", "black"]).asSubquery!"id"()) == 1);
    assert(linksOf(f.c, f.a.id) == sorted([f.blue, f.black]));

    // The unbounded handle still sees everything.
    assert(la.clear() == 2);
}


// ===========================================================================
// Transaction context: rolls back with the transaction
// ===========================================================================

private class Abort : Exception { this() { super("abort"); } }

unittest {
    auto f = fixture();
    f.docs.links!"tags"(f.a.id).add([f.red]);

    assertThrown!Abort(f.c.transaction((ref Transaction tx) {
        auto docs = Repository!(MwDoc, Transaction)(&tx);
        auto change = docs.links!"tags"(f.a.id).set([f.green, f.blue]);
        assert(change.removed == [f.red] && change.added.length == 2);
        throw new Abort();
    }));
    assert(linksOf(f.c, f.a.id) == [f.red], "rolled back with the transaction");

    f.c.transaction((ref Transaction tx) {
        auto docs = Repository!(MwDoc, Transaction)(&tx);
        docs.links!"tags"(f.a.id).set([f.green]);
    });
    assert(linksOf(f.c, f.a.id) == [f.green]);
}


// ===========================================================================
// Model form: inferred keys, self-reference with named keys, prefetch
// ===========================================================================

unittest {
    auto c = makeConn();
    resetSchema(c);
    auto groups = Repository!(MwGroup, Connection)(&c);
    auto perms  = Repository!(MwPerm, Connection)(&c);
    MwGroup g; g.name = "admins"; auto admins = groups.insert(g);
    int[] ids;
    foreach (code; ["read", "write", "delete"]) {
        MwPerm p; p.code = code;
        ids ~= perms.insert(p).id;
    }

    auto l = groups.links!"perms"(admins.id);
    assert(l.set(ids[0 .. 2]).added.length == 2);
    assert(l.add([ids[2]]) == 1);
    assert(l.remove([ids[0]]) == 1);
    auto loaded = groups.query().prefetch!"perms".all();
    int[] got; foreach (p; loaded[0].perms) got ~= p.id;
    assert(sorted(got) == sorted(ids[1 .. 3]));

    // The junction rows went through the junction model's own columns.
    assert(c.execParams(`SELECT count(*) FROM mw_group_perm WHERE group_id = $1`, admins.id)[0][0].as!long == 2);
}

unittest {
    auto c = makeConn();
    resetSchema(c);
    auto nodes = Repository!(MwNode, Connection)(&c);
    int[] ids;
    foreach (label; ["a", "b", "c"]) {
        MwNode n; n.label = label;
        ids ~= nodes.insert(n).id;
    }
    // a -> b, a -> c; b -> c. Keys are named, so direction is checkable.
    assert(nodes.links!"next"(ids[0]).set([ids[1], ids[2]]).added.length == 2);
    assert(nodes.links!"next"(ids[1]).add([ids[2]]) == 1);

    auto loaded = nodes.query().orderBy!"label".prefetch!"next".all();
    assert(loaded[0].next.length == 2);
    assert(loaded[1].next.length == 1 && loaded[1].next[0].label == "c");
    assert(loaded[2].next.length == 0, "c points nowhere: direction was kept");

    assert(nodes.links!"next"(ids[2]).clear() == 0);
    assert(nodes.links!"next"(ids[0]).remove([ids[1]]) == 1);
    assert(c.exec(`SELECT count(*) FROM mw_edge`)[0][0].as!long == 2);
}


// ===========================================================================
// Reserved-word junction names, through every statement
// ===========================================================================

unittest {
    auto f = fixture();
    auto orders = Repository!(MwOrder, Connection)(&f.c);
    MwOrder o; o.code = "SO1"; auto so = orders.insert(o);

    auto l = orders.links!"tags"(so.id);
    assert(l.add([f.red, f.green]) == 2);
    auto change = l.within(f.tags.query().where!"name"("green").asSubquery!"id"()).set([]);
    assert(change.removed == [f.green]);
    assert(l.remove([f.red]) == 1);
    assert(l.add([f.blue]) == 1 && l.clear() == 1);
    l.add([f.blue]);
    auto loaded = orders.query().prefetch!"tags".all();
    assert(loaded.length == 1 && loaded[0].tags.length == 1 && loaded[0].tags[0].name == "blue");
}


// ===========================================================================
// An external junction with no unique constraint: the diff stays honest
// ===========================================================================
//
// ON CONFLICT DO NOTHING has nothing to conflict with here, so only the
// writer's NOT EXISTS guard keeps a second add from inserting a second row.

@model("mw_doc")
struct MwDocLoose {
    @primaryKey int id;
    @many2many!(MwTag, "mw_loose_doc_tag", "doc_id", "tag_id", Junction.external) MwTag[] tags;
}
unittest {
    auto f = fixture();
    f.c.exec(`DROP TABLE IF EXISTS mw_loose_doc_tag;
              CREATE TABLE mw_loose_doc_tag (doc_id int, tag_id int)`);
    auto l = Repository!(MwDocLoose, Connection)(&f.c).links!"tags"(f.a.id);
    assert(l.add([f.red]) == 1);
    assert(l.add([f.red]) == 0, "already linked: nothing inserted");
    assert(!l.set([f.red]).changed);
    assert(f.c.exec(`SELECT count(*) FROM mw_loose_doc_tag`)[0][0].as!long == 1);
    f.c.exec(`DROP TABLE mw_loose_doc_tag`);
}


// ===========================================================================
// A wrong junction column is a server error, not a crash
// ===========================================================================

@model("mw_doc")
struct MwDocBadKey {
    @primaryKey int id;
    @many2many!(MwTag, "mw_doc_tag", "doc_id", "no_such_col", Junction.external) MwTag[] tags;
}
unittest {
    auto f = fixture();
    auto bad = Repository!(MwDocBadKey, Connection)(&f.c);
    assertThrown!QueryServerError(bad.links!"tags"(f.a.id).add([f.red]));
    assertThrown!QueryServerError(bad.links!"tags"(f.a.id).set([f.red]));
    assertThrown!QueryServerError(bad.links!"tags"(f.a.id).remove([f.red]));
    // clear() names only the self key, so a wrong target column cannot fail it.
    assert(bad.links!"tags"(f.a.id).clear() == 0);
}


// ===========================================================================
// Compile-time rejections
// ===========================================================================

// The same junction asked for twice with different columns.
@model("mw_doc")
struct MwDocOther {
    @primaryKey int id;
    @many2many!(MwTag, "mw_doc_tag", "document_id", "tag_id") MwTag[] tags;
}
alias MwBadReg = Registry!(Bind!(MwTag, ModelRepo!MwTag), Bind!(MwDocOther, ModelRepo!MwDocOther));

// A junction model without a unique constraint on the pair.
@model("mw_loose_edge")
struct MwLooseEdge {
    @primaryKey          int id;
    @many2one!(MwNode)   int fromId;
    @many2one!(MwNode)   int toId;
}
@model("mw_node")
struct MwLooseNode {
    @primaryKey int id;
    @many2many!(MwNode, MwLooseEdge, "fromId", "toId") MwNode[] next;
}

// A self-referential junction model with the keys left to inference: both
// FKs point at the parent, so neither key can be chosen.
@model("mw_amb_edge")
@uniqueTogether!("fromId", "toId")
struct MwAmbEdge {
    @primaryKey              int id;
    @many2one!(MwAmbNode)    int fromId;
    @many2one!(MwAmbNode)    int toId;
}
@model("mw_amb_node")
struct MwAmbNode {
    @primaryKey int id;
    @many2many!(MwAmbNode, MwAmbEdge) MwAmbNode[] next;
}

// Both keys named, but the same field.
@model("mw_node")
struct MwSameKeyNode {
    @primaryKey int id;
    @many2many!(MwNode, MwEdge, "fromId", "fromId") MwNode[] next;
}

unittest {
    alias DocRepo = Repository!(MwDoc, Connection);
    static assert(!__traits(compiles, (ref DocRepo r) => r.links!"title"(1)),
        "not a @many2many field");
    static assert(!__traits(compiles, (ref DocRepo r, long[] ids) => r.links!"tags"(1).add(ids)),
        "ids of the wrong key type");
    static assert(!__traits(compiles, (ref DocRepo r, SubQuery!string s) => r.links!"tags"(1).within(s)),
        "a universe of the wrong key type");
    static assert(!__traits(compiles, { struct X { @many2many!(MwTag, "x") MwTag[] t; } }),
        "a string-form junction needs both key columns");
    static assert(!__traits(compiles, { struct X { @many2many!(MwTag, "x", "k", "k") MwTag[] t; } }),
        "one column cannot hold both keys");
    static assert(!__traits(compiles, schemaSQL!MwBadReg()),
        "two declarations of one junction must agree on its columns");
    static assert(!__traits(compiles, Links!(MwLooseNode, "next", Connection)),
        "a junction model must be unique on the pair");
    static assert(!__traits(compiles, Links!(MwAmbNode, "next", Connection)),
        "a self-referential junction model cannot infer its keys");
    static assert(!__traits(compiles, (ref Repository!(MwAmbNode, Connection) r) => r.query().prefetch!"next"),
        "prefetch resolves the keys the same way");
    static assert(!__traits(compiles, Links!(MwSameKeyNode, "next", Connection)),
        "one junction field cannot hold both keys");
}
