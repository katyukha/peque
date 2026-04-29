/** Integration tests for joinOne! with multiple FKs to the same target type.
  *
  * Covers:
  *  - Two @many2one!(Address) fields on the same model
  *  - @related("fkFieldName") disambiguates which FK each @related field uses
  *  - joinOne!("invoiceAddress") and joinOne!("deliveryAddress") emit correct
  *    ON clauses (different FK columns, correct prefixed SELECT aliases)
  *  - Accessing sale_order.invoiceAddress.street and deliveryAddress.street
  *  - NULL FK → Nullable.init for that specific @related field only
  **/
module peque.orm.tests.join_multi_fk;

private import std.process: environment;
private import std.typecons: Nullable, nullable;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("mfk_addresses")
struct MfkAddress {
    @primaryKey int    id;
    @field      string street;
    @field      string city;
}

@model("mfk_orders")
struct MfkOrder {
    @primaryKey                         int                id;
    @field                              string             ref_;

    @many2one!(MfkAddress)              int                invoiceAddressId;
    @related("invoiceAddressId")        Nullable!MfkAddress invoiceAddress;

    @many2one!(MfkAddress)              Nullable!int       deliveryAddressId;
    @related("deliveryAddressId")       Nullable!MfkAddress deliveryAddress;
}

alias MfkReg = Registry!(
    Bind!(MfkAddress, ModelRepo!MfkAddress),
    Bind!(MfkOrder,   ModelRepo!MfkOrder),
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
    c.exec("DROP TABLE IF EXISTS mfk_orders;");
    c.exec("DROP TABLE IF EXISTS mfk_addresses;");
    c.exec(schemaSQL!MfkReg());
}


// ---------------------------------------------------------------------------
// Integration — two @related fields to the same table, different ON columns
// ---------------------------------------------------------------------------

unittest {
    auto c        = makeConn();
    setup(c);
    auto addresses = Repository!(MfkAddress, Connection)(&c);
    auto orders    = Repository!(MfkOrder,   Connection)(&c);

    auto inv  = MfkAddress(0, "12 Invoice St", "London");
    auto del  = MfkAddress(0, "99 Depot Rd",   "Manchester");
    auto inv2 = addresses.insert(inv);
    auto del2 = addresses.insert(del);

    auto o = MfkOrder(0, "SO-001", inv2.id, Nullable!MfkAddress.init,
                      del2.id.nullable, Nullable!MfkAddress.init);
    auto inserted = orders.insert(o);

    auto rows = orders.query()
        .joinOne!("invoiceAddress")
        .joinOne!("deliveryAddress")
        .all();

    assert(rows.length == 1);
    assert(!rows[0].invoiceAddress.isNull);
    assert(!rows[0].deliveryAddress.isNull);
    assert(rows[0].invoiceAddress.get.street  == "12 Invoice St");
    assert(rows[0].deliveryAddress.get.street == "99 Depot Rd");
    assert(rows[0].invoiceAddress.get.city    == "London");
    assert(rows[0].deliveryAddress.get.city   == "Manchester");
}

unittest {
    // NULL deliveryAddressId → deliveryAddress is Nullable.init, invoiceAddress still populated
    auto c        = makeConn();
    setup(c);
    auto addresses = Repository!(MfkAddress, Connection)(&c);
    auto orders    = Repository!(MfkOrder,   Connection)(&c);

    auto inv = MfkAddress(0, "1 Billing Ave", "Bristol");
    auto inv2 = addresses.insert(inv);

    auto o = MfkOrder(0, "SO-002", inv2.id, Nullable!MfkAddress.init,
                      Nullable!int.init, Nullable!MfkAddress.init);
    orders.insert(o);

    auto rows = orders.query()
        .joinOne!("invoiceAddress")
        .joinOne!("deliveryAddress")
        .all();

    assert(rows.length == 1);
    assert(!rows[0].invoiceAddress.isNull);
    assert(rows[0].invoiceAddress.get.street == "1 Billing Ave");
    assert(rows[0].deliveryAddress.isNull);
}
