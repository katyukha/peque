/** What `import peque;` alone must provide — the surface the docs rely on. **/
module peque.tests.doc_imports;

import std.typecons: Nullable;

import peque;   // and nothing else — that is the point


@model("doc_imports_partner")
struct DocPartner {
    @primaryKey int    id;
    @field      string name;
}

// A model using the relation UDAs must compile against the core package alone:
// @many2one marks a real column that core hydration reads, and a model that
// declares @related / @one2many / @many2many must still be expressible here.
@model("doc_imports_order")
struct DocOrder {
    @primaryKey             int                 id;
    @field                  string              title;
    @many2one!(DocPartner)  Nullable!int        partnerId;
    @related                Nullable!DocPartner partner;
    @one2many!(DocLine, "orderId") DocLine[]    lines;
}

@model("doc_imports_line")
struct DocLine {
    @primaryKey          int id;
    @many2one!(DocOrder) int orderId;
}

@autoHydrate
struct DocSummary { int id; string name; }

unittest {
    // Hydration-relevant UDAs are reachable from `import peque;`.
    static assert(__traits(compiles, model("t")));
    static assert(__traits(compiles, field("c")));
    static assert(__traits(compiles, primaryKey.init));
    static assert(__traits(compiles, autoHydrate.init));
    static assert(__traits(compiles, OnDelete.cascade));
    static assert(hasMany2OneUDA!(__traits(getMember, DocOrder, "partnerId")),
        "core must recognise a @many2one field as a column");
    static assert(!hasMany2OneUDA!(__traits(getMember, DocOrder, "title")));

    // The exception tree is reachable too.
    static assert(__traits(compiles, { try {} catch (QueryError e) {} }));
    static assert(__traits(compiles, { try {} catch (IntegrityError e) {} }));
    static assert(__traits(compiles, { try {} catch (ConnectionError e) {} }));
    static assert(__traits(compiles, { try {} catch (NotSupportedError e) {} }));
    static assert(__traits(compiles, { try {} catch (ResultError e) {} }));
    // Named unconditionally, so a `catch` compiles in static builds too even
    // though only a dynamic one can throw it.
    static assert(__traits(compiles, { try {} catch (LibpqLoadError e) {} }));

    // Schema-only UDAs deliberately stay behind `import peque.orm;` — they mean
    // nothing without the ORM, and exporting names like `check`/`index` from the
    // top-level package would collide with user symbols.
    static assert(!__traits(compiles, pgDefault("0")));
    static assert(!__traits(compiles, uniqueIndex.init));
}
