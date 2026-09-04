/** Integration tests for peque:orm aggregation support.
  *
  * Covers:
  *  - scalar aggregate!() — sum/avg/min/max/count via F!(M, "field") builders
  *  - result-type inference (Nullable!long / Nullable!double / field type)
  *  - empty match set → Nullable.isNull
  *  - aggregate!() combined with join-path WHERE predicates (filter joins)
  *  - groupBy! + annotate! (typed and raw) + grouped select!DTO
  *  - groupByRaw! — an expression as a group key (GROUP BY + SELECT)
  *  - multi-key groupBy!
  *  - having() — alone and combined with where() ($N offset threading)
  *  - orderBy(agg.desc) + limit() on grouped queries
  *  - compile-time rejection of invalid usage
  **/
module peque.orm.tests.aggregate;

private import std.process: environment;
private import std.typecons: Nullable;
private import std.math: isClose;

private import peque.connection: Connection;
private import peque.model: model, field, primaryKey, many2one, related, autoHydrate;
private import peque.orm;


// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

@model("agg_orders")
struct AggOrder {
    @primaryKey int    id;
    @field      string name;
    @field      string region;
}

@model("agg_invoices")
struct AggInvoice {
    @primaryKey            int               id;
    @many2one!(AggOrder)   int               orderId;
    @related               Nullable!AggOrder order;
    @field                 string            status;
    @field                 double            amount;
    @field                 int               qty;
}

alias AggReg = Registry!(
    Bind!(AggOrder,   ModelRepo!AggOrder),
    Bind!(AggInvoice, ModelRepo!AggInvoice),
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

// Shared setup: recreate tables and seed three orders with five invoices.
//
//   order 1 "O-1" EU:  open 100.0 q1, open 200.0 q2          → sum 300
//   order 2 "O-2" US:  open  50.0 q5, paid 150.0 q3          → sum 200
//   order 3 "O-3" EU:  paid 400.0 q4                         → sum 400
private void seed(ref Connection c) {
    c.exec("DROP TABLE IF EXISTS agg_invoices;");
    c.exec("DROP TABLE IF EXISTS agg_orders;");
    c.exec(schemaSQL!AggReg());

    auto orepo = Repository!(AggOrder, Connection)(&c);
    auto irepo = Repository!(AggInvoice, Connection)(&c);

    AggOrder[] orders;
    foreach (o; [
        AggOrder(0, "O-1", "EU"),
        AggOrder(0, "O-2", "US"),
        AggOrder(0, "O-3", "EU"),
    ]) {
        orders ~= orepo.insert(o);
    }

    foreach (inv; [
        AggInvoice(0, orders[0].id, Nullable!AggOrder.init, "open", 100.0, 1),
        AggInvoice(0, orders[0].id, Nullable!AggOrder.init, "open", 200.0, 2),
        AggInvoice(0, orders[1].id, Nullable!AggOrder.init, "open",  50.0, 5),
        AggInvoice(0, orders[1].id, Nullable!AggOrder.init, "paid", 150.0, 3),
        AggInvoice(0, orders[2].id, Nullable!AggOrder.init, "paid", 400.0, 4),
    ]) {
        auto rec = inv;
        irepo.insert(rec);
    }
}


// ---------------------------------------------------------------------------
// Scalar aggregate!() — sum, result-type inference
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    // SUM over a double column → Nullable!double
    auto total = repo.query().aggregate!(F!(AggInvoice, "amount").sum);
    static assert(is(typeof(total) == Nullable!double));
    assert(!total.isNull);
    assert(isClose(total.get, 900.0));

    // SUM over an int column → Nullable!long
    auto qtyTotal = repo.query().aggregate!(F!(AggInvoice, "qty").sum);
    static assert(is(typeof(qtyTotal) == Nullable!long));
    assert(qtyTotal.get == 15);

    // Filtered sum
    auto openTotal = repo.query()
        .where!"status"("open")
        .aggregate!(F!(AggInvoice, "amount").sum);
    assert(isClose(openTotal.get, 350.0));
}


// ---------------------------------------------------------------------------
// Scalar aggregate!() — avg, min, max, count
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    // AVG over an int column → Nullable!double (PG returns NUMERIC text)
    auto avgQty = repo.query().aggregate!(F!(AggInvoice, "qty").avg);
    static assert(is(typeof(avgQty) == Nullable!double));
    assert(isClose(avgQty.get, 3.0));

    // MIN / MAX keep the field's own D type
    auto minAmount = repo.query().aggregate!(F!(AggInvoice, "amount").min);
    static assert(is(typeof(minAmount) == Nullable!double));
    assert(isClose(minAmount.get, 50.0));

    auto maxAmount = repo.query().aggregate!(F!(AggInvoice, "amount").max);
    assert(isClose(maxAmount.get, 400.0));

    // MIN on a string column
    auto minStatus = repo.query().aggregate!(F!(AggInvoice, "status").min);
    static assert(is(typeof(minStatus) == Nullable!string));
    assert(minStatus.get == "open");

    // MAX with a filter
    auto maxOpen = repo.query()
        .where!"status"("open")
        .aggregate!(F!(AggInvoice, "amount").max);
    assert(isClose(maxOpen.get, 200.0));

    // COUNT(col) → Nullable!long (COUNT never returns NULL, but the terminal
    // is uniformly Nullable)
    auto n = repo.query().aggregate!(F!(AggInvoice, "id").count);
    static assert(is(typeof(n) == Nullable!long));
    assert(n.get == 5);
}


// ---------------------------------------------------------------------------
// Scalar aggregate!() — empty match set → NULL
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    auto qs = repo.query().where!"status"("no-such-status");
    assert(qs.aggregate!(F!(AggInvoice, "amount").sum).isNull);
    assert(qs.aggregate!(F!(AggInvoice, "amount").avg).isNull);
    assert(qs.aggregate!(F!(AggInvoice, "amount").max).isNull);
    assert(qs.count() == 0);
}


// ---------------------------------------------------------------------------
// Scalar aggregate!() — join-path WHERE predicate (filter join in FROM)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    // Invoices of EU orders: 100 + 200 (order 1) + 400 (order 3)
    auto euTotal = repo.query()
        .where(F!"order.region"("EU"))
        .aggregate!(F!(AggInvoice, "amount").sum);
    assert(isClose(euTotal.get, 700.0));
}


// ---------------------------------------------------------------------------
// groupBy! + annotate! + grouped select!DTO
// ---------------------------------------------------------------------------

@autoHydrate
struct OrderAggDTO {
    int    orderId;
    long   invoiceCount;
    double totalAmount;
}

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    auto totals = repo.query()
        .groupBy!"orderId"
        .annotate!("invoiceCount", F!(AggInvoice, "id").count)
        .annotate!("totalAmount",  F!(AggInvoice, "amount").sum)
        .orderBy(F!(AggInvoice, "orderId"))
        .select!OrderAggDTO();

    assert(totals.length == 3);
    assert(totals[0].invoiceCount == 2 && isClose(totals[0].totalAmount, 300.0));
    assert(totals[1].invoiceCount == 2 && isClose(totals[1].totalAmount, 200.0));
    assert(totals[2].invoiceCount == 1 && isClose(totals[2].totalAmount, 400.0));
}


// ---------------------------------------------------------------------------
// Multi-key groupBy!
// ---------------------------------------------------------------------------

@autoHydrate
struct OrderStatusAggDTO {
    int    orderId;
    string status;
    double totalAmount;
}

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    auto rows = repo.query()
        .groupBy!("orderId", "status")
        .annotate!("totalAmount", F!(AggInvoice, "amount").sum)
        .orderBy(F!(AggInvoice, "orderId"), F!(AggInvoice, "status"))
        .select!OrderStatusAggDTO();

    // Distinct (orderId, status) pairs: (1,open) (2,open) (2,paid) (3,paid)
    assert(rows.length == 4);
    assert(rows[0].orderId == rows[1].orderId - 1);  // order 1 then order 2
    assert(rows[0].status == "open" && isClose(rows[0].totalAmount, 300.0));
    assert(rows[1].status == "open" && isClose(rows[1].totalAmount,  50.0));
    assert(rows[2].status == "paid" && isClose(rows[2].totalAmount, 150.0));
    assert(rows[3].status == "paid" && isClose(rows[3].totalAmount, 400.0));
}


// ---------------------------------------------------------------------------
// having() — alone and combined with where() (placeholder offset threading)
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    // HAVING SUM(amount) > 250 → order 1 (300) and order 3 (400)
    auto big = repo.query()
        .groupBy!"orderId"
        .annotate!("invoiceCount", F!(AggInvoice, "id").count)
        .annotate!("totalAmount",  F!(AggInvoice, "amount").sum)
        .having(F!(AggInvoice, "amount").sum.gt(250.0))
        .orderBy(F!(AggInvoice, "orderId"))
        .select!OrderAggDTO();
    assert(big.length == 2);
    assert(isClose(big[0].totalAmount, 300.0));
    assert(isClose(big[1].totalAmount, 400.0));

    // WHERE ($1) + HAVING ($2): open invoices grouped, sum > 100
    // open sums per order: order 1 → 300, order 2 → 50
    auto bigOpen = repo.query()
        .where!"status"("open")
        .groupBy!"orderId"
        .annotate!("invoiceCount", F!(AggInvoice, "id").count)
        .annotate!("totalAmount",  F!(AggInvoice, "amount").sum)
        .having(F!(AggInvoice, "amount").sum.gt(100.0))
        .select!OrderAggDTO();
    assert(bigOpen.length == 1);
    assert(bigOpen[0].invoiceCount == 2);
    assert(isClose(bigOpen[0].totalAmount, 300.0));

    // Composed HAVING predicate
    auto composed = repo.query()
        .groupBy!"orderId"
        .annotate!("invoiceCount", F!(AggInvoice, "id").count)
        .annotate!("totalAmount",  F!(AggInvoice, "amount").sum)
        .having(F!(AggInvoice, "id").count.gte(2) & F!(AggInvoice, "amount").sum.lt(250.0))
        .select!OrderAggDTO();
    assert(composed.length == 1);
    assert(isClose(composed[0].totalAmount, 200.0));   // order 2
}


// ---------------------------------------------------------------------------
// Raw annotate! escape hatch
// ---------------------------------------------------------------------------

@autoHydrate
struct SpreadDTO {
    int    orderId;
    double amountSpread;
}

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    auto spreads = repo.query()
        .groupBy!"orderId"
        .annotate!("amountSpread", "MAX(_m.amount) - MIN(_m.amount)")
        .orderBy(F!(AggInvoice, "orderId"))
        .select!SpreadDTO();

    assert(spreads.length == 3);
    assert(isClose(spreads[0].amountSpread, 100.0));   // order 1: 200 - 100
    assert(isClose(spreads[1].amountSpread, 100.0));   // order 2: 150 -  50
    assert(isClose(spreads[2].amountSpread,   0.0));   // order 3: single row
}


// ---------------------------------------------------------------------------
// orderBy(agg.desc) + limit() — top group
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    seed(c);
    auto repo = Repository!(AggInvoice, Connection)(&c);

    auto top = repo.query()
        .groupBy!"orderId"
        .annotate!("invoiceCount", F!(AggInvoice, "id").count)
        .annotate!("totalAmount",  F!(AggInvoice, "amount").sum)
        .orderBy(F!(AggInvoice, "amount").sum.desc)
        .limit(1)
        .select!OrderAggDTO();

    assert(top.length == 1);
    assert(isClose(top[0].totalAmount, 400.0));        // order 3
}


// ---------------------------------------------------------------------------
// Compile-time rejection of invalid usage
// ---------------------------------------------------------------------------

@autoHydrate
struct BadDTO {
    int    orderId;
    string status;      // not a group key, not an annotation
}

unittest {
    auto c = makeConn();
    auto repo = Repository!(AggInvoice, Connection)(&c);
    auto qs = repo.query();

    // DTO member that is neither a groupBy! key nor an annotate! alias
    static assert(!__traits(compiles,
        qs.groupBy!"orderId".select!BadDTO()));

    // Unknown / non-column field in groupBy!
    static assert(!__traits(compiles, qs.groupBy!"noSuchField"));
    static assert(!__traits(compiles, qs.groupBy!"order"));      // @related, not a column

    // .sum on a non-numeric field
    static assert(!__traits(compiles, F!(AggInvoice, "status").sum));

    // Aggregates require the typed F!(M, "field") form
    static assert(!__traits(compiles, F!"amount".sum));

    // aggregate!() only accepts AggBuilder specs
    static assert(!__traits(compiles, qs.aggregate!(F!(AggInvoice, "amount"))));
}


// ---------------------------------------------------------------------------
// aggregate! honours limit()/offset()
// ---------------------------------------------------------------------------

// It was the one terminal that neither honoured the bounds nor rejected them:
// count() on the same builder returned 2 while sum() summed every row. Django,
// Ecto and SQLAlchemy all aggregate over the bounded set via a subquery, which
// is what count() already did here.
unittest {
    auto c = makeConn();
    seed(c);                       // amounts 100, 200, 50, 150, 400

    auto repo = Repository!(AggInvoice, Connection)(&c);

    // Unbounded is unchanged.
    assert(repo.query().aggregate!(F!(AggInvoice, "amount").sum)().get == 900.0);

    // With a bound, the aggregate covers exactly the rows all() returns.
    foreach (lim; [0, 1, 3, 9])
        foreach (off; [0, 2]) {
            auto qs = repo.query().orderBy!("amount")().limit(lim).offset(off);
            double expect = 0;
            foreach (ref r; qs.all()) expect += r.amount;
            auto got = qs.aggregate!(F!(AggInvoice, "amount").sum)();
            if (qs.all().length == 0)
                assert(got.isNull, "SUM over zero rows is NULL");
            else
                assert(got.get == expect,
                    "aggregate must cover the rows all() returns");
            assert(qs.count() == qs.all().length);
        }

    // ORDER BY decides which rows a limit selects, so it must reach the
    // subquery: the top two by amount are 400 + 200, not 50 + 100.
    assert(repo.query().orderBy(F!(AggInvoice, "amount").desc).limit(2)
               .aggregate!(F!(AggInvoice, "amount").sum)().get == 600.0);
    assert(repo.query().orderBy(F!(AggInvoice, "amount").asc).limit(2)
               .aggregate!(F!(AggInvoice, "amount").sum)().get == 150.0);
}


// ---------------------------------------------------------------------------
// groupByRaw! — grouping by an expression
// ---------------------------------------------------------------------------

@autoHydrate
struct BandTotals { string band; long n; double total; }

@autoHydrate
struct StatusBand { string status; string band; long n; }

// annotate! projects; groupByRaw! groups. The distinction is the whole point:
// an annotate!()d non-aggregate expression makes PostgreSQL reject the
// statement, because nothing put it in GROUP BY.
unittest {
    auto c = makeConn();
    seed(c);                       // amounts 100, 200, 50, 150, 400

    auto repo = Repository!(AggInvoice, Connection)(&c);

    // A raw key on its own: three bands over five invoices.
    enum band = `CASE WHEN _m.amount >= 200 THEN 'big' ELSE 'small' END`;
    auto bands = repo.query()
        .groupByRaw!("band", band)
        .annotate!("n",     "COUNT(*)")
        .annotate!("total", F!(AggInvoice, "amount").sum)
        .orderBy("band")
        .select!BandTotals();

    assert(bands.length == 2);
    assert(bands[0].band == "big"   && bands[0].n == 2 && bands[0].total == 600.0);
    assert(bands[1].band == "small" && bands[1].n == 3 && bands[1].total == 300.0);

    // Combined with a column key — and the two kinds compose in either order,
    // which is why groupBy! exists on the grouped type as well.
    auto mixed = repo.query()
        .groupBy!"status"
        .groupByRaw!("band", band)
        .annotate!("n", "COUNT(*)")
        .orderBy("status, band")
        .select!StatusBand();

    auto reversed = repo.query()
        .groupByRaw!("band", band)
        .groupBy!"status"
        .annotate!("n", "COUNT(*)")
        .orderBy("status, band")
        .select!StatusBand();
    assert(reversed == mixed);

    assert(mixed.length == 4);
    assert(mixed[0].status == "open" && mixed[0].band == "big"   && mixed[0].n == 1);
    assert(mixed[1].status == "open" && mixed[1].band == "small" && mixed[1].n == 2);
    assert(mixed[2].status == "paid" && mixed[2].band == "big"   && mixed[2].n == 1);
    assert(mixed[3].status == "paid" && mixed[3].band == "small" && mixed[3].n == 1);

    // where() still applies before grouping, and having() after it.
    auto openOnly = repo.query()
        .where!"status"("open")
        .groupByRaw!("band", band)
        .annotate!("n",     "COUNT(*)")
        .annotate!("total", F!(AggInvoice, "amount").sum)
        // open invoices are 100, 200, 50 -> big = 200, small = 150
        .having(F!(AggInvoice, "amount").sum.gt(180.0))
        .select!BandTotals();

    assert(openOnly.length == 1);
    assert(openOnly[0].band == "big" && openOnly[0].n == 1 && openOnly[0].total == 200.0);
}

// The compile-time contract.
unittest {
    auto c = makeConn();
    auto repo = Repository!(AggInvoice, Connection)(&c);
    auto qs = repo.query();
    enum band = `CASE WHEN _m.amount >= 200 THEN 'big' ELSE 'small' END`;

    // A DTO member matching neither a key nor an annotation is still rejected.
    static assert(!__traits(compiles,
        qs.groupByRaw!("band", band).select!BandTotals()));   // no "n"/"total"

    // An empty name or expression is refused rather than emitting broken SQL.
    static assert(!__traits(compiles, qs.groupByRaw!("", band)));
    static assert(!__traits(compiles, qs.groupByRaw!("band", "")));

    // One name cannot be claimed twice — the duplicate would be silently
    // dropped, which is a wrong answer rather than an error.
    static assert(!__traits(compiles,
        qs.groupBy!"status"
          .groupByRaw!("status", band)
          .annotate!("n", "COUNT(*)")
          .select!StatusBand()));
    static assert(!__traits(compiles,
        qs.groupByRaw!("band", band)
          .annotate!("band", "COUNT(*)")
          .annotate!("n", "COUNT(*)")
          .select!StatusBand()));

    // Grouped queries have no row terminals, raw key or not.
    static assert(!__traits(compiles, qs.groupByRaw!("band", band).all()));
    static assert(!__traits(compiles, qs.groupByRaw!("band", band).first()));
}
