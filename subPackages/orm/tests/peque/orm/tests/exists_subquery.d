/** Integration tests for EXISTS / NOT EXISTS subquery predicates in peque:orm.
  *
  * Covers:
  *  - exists!(M)(inner) emits correct SQL
  *  - ~exists!(M)(inner) emits NOT EXISTS
  *  - SF!(M, "field")(F!(Outer, "pk")) column-to-column correlation
  *  - SF!(M, "field")(value) value predicate inside subquery
  *  - exists! combined with other WHERE clauses via &
  *  - row counts: EXISTS returns only rows where subquery matches
  *  - NOT EXISTS returns rows where subquery has no match
  **/
module peque.orm.tests.exists_subquery;

private import std.process: environment;
private import std.typecons: Nullable;
private import std.exception: assertThrown;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one;
private import peque.exception: PequeException;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("eq_orders")
struct EqOrder {
    @primaryKey int    id;
    @field      string ref_;
    @field      string status;
}

@model("eq_invoices")
struct EqInvoice {
    @primaryKey int    id;
    @field      int    orderId;
    @field      string status;
}

alias EqReg = Registry!(
    Bind!(EqOrder,   ModelRepo!EqOrder),
    Bind!(EqInvoice, ModelRepo!EqInvoice),
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

private void setup(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS eq_invoices;");
    c.exec("DROP TABLE IF EXISTS eq_orders;");
    c.exec(schemaSQL!EqReg());
}


// ---------------------------------------------------------------------------
// SQL generation (compile-time / CTFE)
// ---------------------------------------------------------------------------

unittest {
    import peque.orm.predicate: serializePredicate;

    auto pred = exists!(EqInvoice)(
        SF!(EqInvoice, "orderId")(F!(EqOrder, "id")) &
        SF!(EqInvoice, "status")("open")
    );
    auto s = serializePredicate(pred);
    import std.string: indexOf;
    // Identifiers are emitted quoted; compare against the unquoted shape.
    string bare;
    foreach (char ch; s.sql) if (ch != '"') bare ~= ch;
    assert(bare.indexOf("EXISTS (SELECT 1 FROM eq_invoices _sq WHERE") >= 0,
        "expected EXISTS clause, got: " ~ s.sql);
    assert(bare.indexOf("_sq.orderId = _m.id") >= 0,
        "expected column correlation, got: " ~ s.sql);
    assert(bare.indexOf("_sq.status = $1") >= 0,
        "expected status predicate, got: " ~ s.sql);
    assert(s.params.length == 1);
}

unittest {
    import peque.orm.predicate: serializePredicate;

    auto pred = ~exists!(EqInvoice)(
        SF!(EqInvoice, "orderId")(F!(EqOrder, "id"))
    );
    auto s = serializePredicate(pred);
    import std.string: indexOf;
    assert(s.sql.indexOf("NOT (EXISTS") >= 0,
        "expected NOT EXISTS, got: " ~ s.sql);
    assert(s.params.length == 0);
}


// ---------------------------------------------------------------------------
// Integration — EXISTS filters rows correctly
// ---------------------------------------------------------------------------

unittest {
    auto c     = makeConn();
    setup(c);
    auto orders   = Repository!(EqOrder,   Connection)(&c);
    auto invoices = Repository!(EqInvoice, Connection)(&c);

    auto r1 = EqOrder(0, "ORD-1", "draft");
    auto r2 = EqOrder(0, "ORD-2", "draft");
    auto r3 = EqOrder(0, "ORD-3", "draft");
    auto o1 = orders.insert(r1);
    auto o2 = orders.insert(r2);
    auto o3 = orders.insert(r3);

    // o1 has an open invoice, o2 has only a paid invoice, o3 has no invoices
    auto i1 = EqInvoice(0, o1.id, "open");
    auto i2 = EqInvoice(0, o2.id, "paid");
    invoices.insert(i1);
    invoices.insert(i2);

    // EXISTS: orders that have at least one open invoice → only o1
    auto withOpen = orders.query()
        .where(
            exists!(EqInvoice)(
                SF!(EqInvoice, "orderId")(F!(EqOrder, "id")) &
                SF!(EqInvoice, "status")("open")
            )
        )
        .all();
    assert(withOpen.length == 1);
    assert(withOpen[0].ref_ == "ORD-1");
}

unittest {
    auto c     = makeConn();
    setup(c);
    auto orders   = Repository!(EqOrder,   Connection)(&c);
    auto invoices = Repository!(EqInvoice, Connection)(&c);

    auto r1 = EqOrder(0, "ORD-1", "draft");
    auto r2 = EqOrder(0, "ORD-2", "draft");
    auto r3 = EqOrder(0, "ORD-3", "draft");
    auto o1 = orders.insert(r1);
    auto o2 = orders.insert(r2);
    auto o3 = orders.insert(r3);

    auto i1 = EqInvoice(0, o1.id, "open");
    auto i2 = EqInvoice(0, o2.id, "paid");
    invoices.insert(i1);
    invoices.insert(i2);

    // NOT EXISTS: orders with no invoices at all → only o3
    auto withoutAny = orders.query()
        .where(~exists!(EqInvoice)(
            SF!(EqInvoice, "orderId")(F!(EqOrder, "id"))
        ))
        .all();
    assert(withoutAny.length == 1);
    assert(withoutAny[0].ref_ == "ORD-3");
}

unittest {
    auto c     = makeConn();
    setup(c);
    auto orders   = Repository!(EqOrder,   Connection)(&c);
    auto invoices = Repository!(EqInvoice, Connection)(&c);

    auto r1 = EqOrder(0, "ORD-1", "closed");
    auto r2 = EqOrder(0, "ORD-2", "draft");
    auto r3 = EqOrder(0, "ORD-3", "draft");
    auto o1 = orders.insert(r1);
    auto o2 = orders.insert(r2);
    auto o3 = orders.insert(r3);

    auto i1 = EqInvoice(0, o1.id, "open");
    auto i2 = EqInvoice(0, o2.id, "open");
    invoices.insert(i1);
    invoices.insert(i2);

    // EXISTS combined with another WHERE clause
    // → draft orders that have an open invoice → only o2
    auto res = orders.query()
        .where(F!(EqOrder, "status")("draft"))
        .where(exists!(EqInvoice)(
            SF!(EqInvoice, "orderId")(F!(EqOrder, "id")) &
            SF!(EqInvoice, "status")("open")
        ))
        .all();
    assert(res.length == 1);
    assert(res[0].ref_ == "ORD-2");
}


// ---------------------------------------------------------------------------
// Nested EXISTS — must throw PequeException at serialisation time, not produce
// silently wrong SQL (both levels would alias to _sq)
// ---------------------------------------------------------------------------

unittest {
    import peque.orm.predicate: serializePredicate;

    // Build a nested exists: exists!(EqOrder)(... exists!(EqInvoice)(...) ...)
    // This is statically constructable; the error fires at serialisation.
    auto inner = exists!(EqInvoice)(
        SF!(EqInvoice, "orderId")(F!(EqOrder, "id"))
    );
    auto outer = exists!(EqOrder)(inner);

    assertThrown!PequeException(serializePredicate(outer),
        "nested exists!() must throw PequeException at serialisation time");
}

unittest {
    import peque.orm.predicate: serializePredicate;

    // NOT EXISTS wrapping a nested EXISTS must also be caught.
    auto inner = exists!(EqInvoice)(
        SF!(EqInvoice, "orderId")(F!(EqOrder, "id"))
    );
    auto outer = ~exists!(EqOrder)(inner);

    assertThrown!PequeException(serializePredicate(outer),
        "~exists!() wrapping a nested exists!() must throw PequeException");
}

unittest {
    // Via QuerySet.where() — the error propagates to the terminal method caller.
    auto c = makeConn();
    setup(c);
    auto orders = Repository!(EqOrder, Connection)(&c);

    auto inner = exists!(EqInvoice)(
        SF!(EqInvoice, "orderId")(F!(EqOrder, "id"))
    );
    auto outer = exists!(EqOrder)(inner);

    assertThrown!PequeException(
        orders.query().where(outer).all(),
        "nested exists!() via QuerySet.where().all() must throw PequeException");
}
