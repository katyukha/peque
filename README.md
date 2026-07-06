# Peque — PostgreSQL client for D

Peque is a lightweight [libpq](https://www.postgresql.org/docs/current/libpq.html)
wrapper for the D programming language.

It uses `SafeRefCounted` (from `std.typecons`) to manage libpq objects
deterministically — connections and results are freed as soon as they go out of
scope, without depending on the GC.

## Features

- Reference-counted `Connection` and `Result` — deterministic cleanup, no GC dependency
- Parameterized queries via `execParams` — SQL injection safe by design
- Automatic bidirectional type conversion between PostgreSQL text format and D types
- `Nullable!T` support for NULL columns
- RAII transaction helper with auto-commit / auto-rollback on exception
- Configurable transaction isolation level (`readCommitted`, `repeatableRead`, `serializable`, `serverDefault`)
- Savepoint support for partial rollbacks within a transaction
- Static or dynamic (`bindbc-loader`) loading of `libpq`
- **`peque:orm`** — compile-time ORM with type-safe WHERE predicates, QuerySet, and schema generation
- **`peque:migrate`** — compile-time D-struct migration runner with rollback and checksum verification
- **`peque:vibe`** — vibe.d fiber-aware integration (`VibeWaitStrategy` + `VibeConnectionPool`)

## Supported types

| D type | PostgreSQL type |
|---|---|
| `string` | `text`, `varchar`, `char`, … |
| `JSONValue` | `json`, `jsonb` |
| `int`, `long`, `short` | `integer`, `bigint`, `smallint` |
| `float`, `double` | `real`, `double precision` (incl. `NaN`, `Infinity`, `-Infinity`) |
| `bool` | `boolean` |
| `Date` | `date` |
| `DateTime` | `timestamp` |
| `SysTime` | `timestamptz` |
| `T[]` | one-dimensional arrays |
| `Nullable!T` | any nullable column |

## Installation

`dub.json`:
```json
"dependencies": {
    "peque": "~>0.1.0"
}
```

`dub.sdl`:
```
dependency "peque" version="~>0.1.0"
```

Sub-packages are opt-in:

```
dependency "peque:orm"     version="~>0.1.0"   // ORM layer
dependency "peque:migrate" version="~>0.1.0"   // migration runner
dependency "peque:vibe"    version="~>0.1.0"   // vibe.d integration
```

Choose a configuration depending on how you want to link `libpq`:

| Configuration | Description |
|---|---|
| `libraryStatic` | Static library — links `libpq` directly |
| `libraryDynamic` | Dynamic library — loads `libpq` at runtime via `bindbc-loader` |

## Quick start

```d
import peque;
import std.stdio;

auto c = Connection(
    dbname: "mydb",
    user:   "myuser",
    password: "secret",
    host:   "localhost",
    port:   "5432",
);

// Raw SQL — fine for DDL or trusted input
c.exec("
    CREATE TABLE IF NOT EXISTS items (id serial, name text, qty int);
    INSERT INTO items (name, qty) VALUES ('apple', 5), ('banana', 3);
");

// Parameterized query — SQL-injection safe
auto res = c.execParams(
    "SELECT name, qty FROM items WHERE qty > $1", 2);

foreach (row; res)
    writeln(row["name"].get!string, ": ", row["qty"].get!int);

// Nullable column
auto maybeQty = res[0]["qty"].get!(Nullable!int);
if (!maybeQty.isNull)
    writeln(maybeQty.get);
```

## Prepared statements

`Connection.prepare()` registers a server-side prepared statement and returns a
move-only `PreparedStatement` handle. Its destructor issues `DEALLOCATE`
automatically when it goes out of scope.

```d
auto stmt = conn.prepare("find_user",
    "SELECT id, name FROM users WHERE id = $1");

auto result = stmt.exec(42);
// stmt goes out of scope → DEALLOCATE find_user sent automatically
```

Useful when the same query runs many times in the same connection session — the
server parses and plans it once.

## Transactions

`Connection.transaction()` runs a delegate inside a `BEGIN`/`COMMIT` block.
On exception the transaction is always rolled back. The delegate receives a
`ref Transaction` handle that exposes `exec`, `execParams`, and `escapeString`
but intentionally hides `commit()` and `rollback()` — making accidental early
termination of the transaction a **compile-time error** rather than a silent
runtime bug.

```d
c.transaction((ref tx) {
    tx.execParams("INSERT INTO items (name, qty) VALUES ($1, $2)", "cherry", 10);
    tx.execParams("UPDATE items SET qty = qty - 1 WHERE name = $1", "apple");
});
```

`transaction()` can return a value:

```d
auto newQty = c.transaction((ref tx) {
    tx.execParams("UPDATE items SET qty = qty - 1 WHERE name = $1", "apple");
    return tx.execParams(
        "SELECT qty FROM items WHERE name = $1", "apple")[0][0].get!int;
});
```

Use `OnSuccess.rollback` for dry-runs or test helpers that must not persist
changes:

```d
c.transaction!(OnSuccess.rollback)((ref tx) {
    tx.execParams("DELETE FROM items");
    auto count = tx.execParams("SELECT count(*) FROM items")[0][0].get!long;
    assert(count == 0);
    // transaction is rolled back after the delegate returns
});
```

### Savepoints

`Transaction.savepoint()` creates a PostgreSQL savepoint. On exception, only
the savepoint changes are rolled back — the enclosing transaction remains open
and intact.

```d
c.transaction((ref tx) {
    tx.execParams("INSERT INTO items (name, qty) VALUES ($1, $2)", "date", 7);

    try {
        tx.savepoint((ref tx) {
            tx.execParams(
                "INSERT INTO items (name, qty) VALUES ($1, $2)", "elderberry", 2);
            throw new Exception("changed my mind");
            // only the elderberry insert is rolled back
        });
    } catch (Exception e) {}

    // date is still in the transaction and will be committed
});
```

### Isolation levels

```d
// Read committed (default)
c.transaction((ref tx) { ... });

// Repeatable read
c.transaction!(OnSuccess.commit, IsolationLevel.repeatableRead)((ref tx) { ... });

// Serializable — may abort; application must be prepared to retry
c.transaction!(OnSuccess.commit, IsolationLevel.serializable)((ref tx) { ... });

// Server default — defers to postgresql.conf / ALTER ROLE / ALTER DATABASE
c.transaction!(OnSuccess.commit, IsolationLevel.serverDefault)((ref tx) { ... });
```

---

## ORM (`peque:orm`)

`peque:orm` is a compile-time ORM that generates SQL from model UDA metadata.
Nothing is reflected at runtime — all column names, table names, and SELECT
lists are computed by the compiler.

### Model definition

```d
import peque.orm;

@model("res_partner")
struct Partner {
    @primaryKey int    id;
    @field      string name;
    @field      string email;
    @field      bool   active;
}
```

### Column constraints and indexes

```d
@model("products")
@uniqueTogether!("name", "tenant_id")
@checkConstraint("chk_price", "price > 0")
@indexTogether!("category_id", "active")
@uniqueIndexTogether!("tenant_id", "slug")
struct Product {
    @primaryKey                                int    id;
    @field @unique @index                      string sku;
    @field @check("price > 0")                 double price;
    @field @pgDefault("true")                  bool   active;
    @field @pgDefault("0") @pgNotNull          Nullable!int stock;
    @field @pgType("NUMERIC(10,2)")            double cost;
    @field @uniqueIndex                        string slug;
    @field @uniqueIndex(where: "active = true") string externalId;
    @field @ginIndex                           JSONValue metadata;
    @field @hashIndex                          string sessionToken;
    @field @gistIndex                          string location;
}
```

Index name convention (all checked against PostgreSQL's 63-byte limit at compile time):

| UDA | Prefix | Method |
|---|---|---|
| `@index` | `idx_` | btree (default, no `USING`) |
| `@uniqueIndex` | `uniq_` | btree |
| `@ginIndex` | `gin_` | `USING gin` |
| `@gistIndex` | `gist_` | `USING gist` |
| `@hashIndex` | `hash_` | `USING hash` |
| `@indexTogether` | `idx_` | btree |
| `@uniqueIndexTogether` | `uniq_` | btree |

### Registry and schema

A `Registry` maps models to repository templates. `schemaSQL` generates
`CREATE TABLE` statements for every model in the registry.

```d
alias AppReg = Registry!(Bind!(Partner, ModelRepo!Partner));

// On first run / migration:
conn.exec(schemaSQL!AppReg());
```

### Repository CRUD

```d
auto repo = Repository!(Partner, Connection)(&conn);

// Insert — returns the row with server-assigned id
auto p = repo.insert(Partner(0, "Acme Corp", "info@acme.com", true));

// Fetch by primary key — returns Nullable!Partner
auto found = repo.findById(p.id);

// Update entire row
p.name = "Acme Ltd";
repo.update(p);

// Delete by primary key
repo.deleteById(p.id);

// Check existence without fetching the row
bool here = repo.existsById(p.id);

// Insert multiple records in a single round-trip
auto many = repo.insertMany([
    Partner(0, "Acme Corp", "info@acme.com", true),
    Partner(0, "Beta Ltd",  "hi@beta.com",   true),
]);

// Upsert by primary key — plain INSERT when PK is 0/init, ON CONFLICT UPDATE otherwise
auto saved = repo.upsert(p);

// Upsert by natural key — conflict on any UNIQUE column(s)
auto saved2 = repo.upsert!"email"(p);

// Delete a record by value (extracts PK internally)
repo.deleteByRec(p);

// Bulk delete — single IN-clause round-trip; returns count deleted
long n = repo.deleteByRec(many);
```

### QuerySet

`repo.query()` returns a lazy `QuerySet`. Filters accumulate without touching
the database; a terminal method sends the query.

```d
// All active partners
auto active = repo.query().where!"active"(true).all();

// Filtered, ordered, paginated
auto page = repo.query()
    .where!"active"(true)
    .orderBy("name ASC")
    .limit(10).offset(20)
    .all();

// Count
long n = repo.query().where!"active"(true).count();

// Exists
bool any = repo.query().where!"active"(true).exists();

// First match — returns Nullable!Partner
auto first = repo.query().where!"name"("Acme Ltd").first();

// Delete matching rows — returns count deleted
long deleted = repo.query().where!"active"(false).delete_();

// Partial update — set only named fields
long updated = repo.query()
    .where!"active"(false)
    .set!"name"("Archived")
    .update();

// none() — force empty result (useful when building conditional filters)
auto qs = allowedIds.empty ? repo.query().none()
                           : repo.query().whereIn!"id"(allowedIds);

// select!DTO() — project into a different struct
struct PartnerSummary { int id; string name; }
PartnerSummary[] summaries = repo.query()
    .where!"active"(true)
    .select!PartnerSummary();
```

### Aggregation

Scalar aggregates run through `aggregate!()` with a typed field builder.
The result is `Nullable` — `SUM`/`AVG`/`MIN`/`MAX` over zero rows is SQL `NULL`:

```d
// SELECT SUM(_m.amount) FROM invoices _m WHERE (_m.status = $1)
Nullable!double total = repo.query()
    .where!"status"("open")
    .aggregate!(F!(Invoice, "amount").sum);

auto avgQty  = repo.query().aggregate!(F!(Invoice, "qty").avg);      // Nullable!double
auto maxDate = repo.query().aggregate!(F!(Invoice, "createdAt").max); // field's own type
```

Grouped reports use `groupBy!` + `annotate!` + `select!DTO`. Every DTO member
must be a group key or an annotation alias — checked at compile time, so
PostgreSQL's "column must appear in the GROUP BY clause" is a build error, not
a runtime one:

```d
@autoHydrate
struct OrderTotalsDTO { int orderId; long invoiceCount; double totalAmount; }

auto totals = invoiceRepo.query()
    .where!"status"("open")
    .groupBy!"orderId"
    .annotate!("invoiceCount", F!(Invoice, "id").count)
    .annotate!("totalAmount",  F!(Invoice, "amount").sum)
    .having(F!(Invoice, "amount").sum.gt(100.0))       // filter groups
    .orderBy(F!(Invoice, "amount").sum.desc)           // order by aggregate
    .select!OrderTotalsDTO();

// Raw-SQL annotation escape hatch (trusted, compile-time strings only):
.annotate!("amountSpread", "MAX(_m.amount) - MIN(_m.amount)")
```

Group keys are main-table columns; aggregating across a one2many is done by
querying from the "many" side (as above: invoices grouped by `orderId`).

### Type-safe predicates

`F!(Model, "field")` builds a compile-time field reference. Unknown field names
are compile-time errors.

```d
import peque.orm;

// Comparison operators
repo.query().where(F!(Partner, "id").gte(100)).all();
repo.query().where(F!(Partner, "name").like("Acme%")).all();
repo.query().where(F!(Partner, "name").ne("Ghost")).all();

// IN
repo.query().where(F!(Partner, "id").contains([1, 2, 3])).all();
// or sugar:
repo.query().whereIn!"id"([1, 2, 3]).all();

// IS NULL
repo.query().where(F!(Partner, "email").isNull).all();

// OR / AND / NOT composition
auto pred = F!(Partner, "active")(true) & F!(Partner, "id").gte(10);
repo.query().where(pred).all();

auto orPred = F!(Partner, "name")("Acme") | F!(Partner, "name")("Beta");
repo.query().where(orPred).all();

repo.query().where(~F!(Partner, "active")(false)).all();
```

The type-free variant `F!"fieldName"` infers the column name from the
camelCase→snake_case convention without model validation. Field-name typos
become PostgreSQL runtime errors rather than compile-time failures — use
`F!(Model, "field")` when compile-time checking is preferred.

```d
repo.query().where(F!"active"(true)).all();
repo.query().where(F!"id".gte(10)).all();
```

### Raw SQL escape hatch

`whereRaw` embeds a SQL fragment verbatim — placeholders use local `$1`/`$2`
numbering and are renumbered automatically relative to prior filters.

```d
repo.query().whereRaw("tsv @@ to_tsquery($1)", "acme & corp").all();
```

**Security:** `sqlFrag` is embedded in the query verbatim — never pass
user-controlled input as the first argument. All runtime values must go through
the variadic args.

### EXISTS subqueries

```d
@model("invoices")
struct Invoice {
    @primaryKey int    id;
    @field      int    partnerId;
    @field      string status;
}

alias InvoiceRepo = Repository!(Invoice, Connection);

// Partners that have at least one open invoice
partnerRepo.query()
    .where(
        exists!(Invoice)(
            SF!(Invoice, "partnerId")(F!(Partner, "id")) &
            SF!(Invoice, "status")("open")
        )
    )
    .all();

// Partners with NO invoices at all
partnerRepo.query()
    .where(~exists!(Invoice)(
        SF!(Invoice, "partnerId")(F!(Partner, "id"))
    ))
    .all();
```

Note: single-level `exists!()` only. Nested `exists!()` calls conflict on the
`_sq` alias and throw `PequeException` at serialisation time.

### IN subqueries

`asSubquery!"field"()` captures a QuerySet as a single-column subquery atom
without hitting the database. Pass it to `F!(M,"field").inSubquery()` for
`IN (SELECT …)`, or negate with `~` for `NOT IN`.

```d
// IDs of active categories — no DB call yet
auto activeCatIds = catRepo.query()
    .where!"active"(true)
    .asSubquery!"id"();

// Products whose category is in that set
auto products = prodRepo.query()
    .where(F!(Product, "categoryId").inSubquery(activeCatIds))
    .all();

// Products whose category is NOT in that set
auto rest = prodRepo.query()
    .where(~F!(Product, "categoryId").inSubquery(activeCatIds))
    .all();
```

---

## Migrations (`peque:migrate`)

Migrations are plain D structs compiled into the application binary. Each
struct has `up()` and optionally `down()`. Version numbers are assigned by
position in `MigrationList` — never reorder migrations.

```d
import peque;
import peque.migrate;

struct V1_CreateUsers {
    enum description = "create users table";
    void up(ref Connection conn) {
        conn.exec(`CREATE TABLE users (
            id    serial PRIMARY KEY,
            name  text   NOT NULL,
            email text   NOT NULL DEFAULT ''
        )`);
    }
    void down(ref Connection conn) {
        conn.exec(`DROP TABLE users`);
    }
}

struct V2_AddIndex {
    enum description = "index users.email";
    void up(ref Connection conn) {
        conn.exec(`CREATE INDEX ON users (email)`);
    }
    // no down() — irreversible; rollback throws MigrationError
}

alias AppMigrations = MigrationList!(V1_CreateUsers, V2_AddIndex);
```

### Running migrations

```d
auto m = Migrator!(AppMigrations)(&conn, "myapp");

m.migrate();          // apply all pending (advisory-locked, each in its own transaction)
m.rollback(1);        // roll back the last applied migration (requires down())
m.status();           // returns MigrationStatus[] with applied / pending info
```

### Integration with `peque:orm`

The first migration can reuse `schemaSQL` to create all ORM-managed tables:

```d
struct V1_InitSchema {
    enum description = "create all tables";
    void up(ref Connection conn) {
        conn.exec(schemaSQL!AppReg());
    }
}
```

### Multiple namespaces

Libraries and applications can share a database with independent version
sequences:

```d
Migrator!(LibMigrations)(&conn, "mylib").migrate();
Migrator!(AppMigrations)(&conn, "myapp").migrate();
```

### Checksum verification

Each migration's checksum (SHA-256 of its fully-qualified name + description)
is stored on first apply. Re-running `migrate()` after editing an already-applied
migration throws `MigrationError` rather than silently re-applying or skipping.

---

## vibe.d (`peque:vibe`)

`peque:vibe` provides a fiber-aware wait strategy and connection pool for
vibe.d applications. Instead of blocking the OS thread while waiting for
PostgreSQL, control yields to the vibe.d event loop.

```d
dependency "peque:vibe" version="~>0.1.0"
```

```d
import peque;
import peque.vibe;

// Single connection with fiber-aware I/O
auto conn = Connection(params, VibeWaitStrategy());

// Connection pool — makeVibePool injects VibeWaitStrategy and non-blocking mode
auto pool = makeVibePool(8, [
    "dbname": "myapp",
    "user":   "app",
    "host":   "localhost",
    "port":   "5432",
]);

// Borrow a connection for the duration of a delegate; returned automatically
auto result = pool.borrow((ref Connection conn) {
    return conn.execParams("SELECT name FROM users WHERE id = $1", userId);
});
```

---


## vibe.d (`peque:vibe`)

`peque:vibe` provides a fiber-aware wait strategy and connection pool for
vibe.d applications. Instead of blocking the OS thread while waiting for
PostgreSQL, control yields to the vibe.d event loop.

```d
dependency "peque:vibe" version="~>0.1.0"
```

```d
import peque;
import peque.vibe;

// Single connection with fiber-aware I/O
auto conn = Connection(params, VibeWaitStrategy());

// Connection pool — makeVibePool injects VibeWaitStrategy and non-blocking mode
auto pool = makeVibePool(8, [
    "dbname": "myapp",
    "user":   "app",
    "host":   "localhost",
    "port":   "5432",
]);

// Borrow a connection for the duration of a delegate; returned automatically
auto result = pool.borrow((ref Connection conn) {
    return conn.execParams("SELECT name FROM users WHERE id = $1", userId);
});
```

---

## LISTEN / NOTIFY

peque exposes PostgreSQL's notification bus: `listen()`/`unlisten()` subscribe
a connection to channels, and `waitNotifications(Duration)` delivers
`Notification { channel, payload, backendPid }` values with a bounded wait —
the shape a server-sent-events hub or cache invalidator needs.

```d
import core.time: seconds;
import peque;

// The listening connection must be DEDICATED: autocommit (no open
// transactions — the server delivers notifications only between
// transactions), never pooled, owned by a single consumer loop.
auto conn = Connection(params);            // or Connection(params, VibeWaitStrategy())
conn.listen("events");                     // channel name is identifier-quoted

bool running = true;
while (running) {
    // Bounded wait doubles as the heartbeat tick: empty result on timeout.
    foreach (n; conn.waitNotifications(30.seconds))
        dispatch(n.channel, n.payload);
    // ...check stop flag, send SSE heartbeat, verify conn.status() here...
}
```

Publishing needs no dedicated API — `pg_notify` is a regular parameterized
query, and NOTIFY is transactional (delivered on COMMIT, discarded on
ROLLBACK):

```d
conn.execParams("SELECT pg_notify($1, $2)", "events", payload);
```

`getNotifications()` is the non-blocking variant (drain only, never waits).
`waitNotifications` drains libpq's buffer *before* waiting, so notifications
that arrived during earlier traffic are returned immediately; a zero timeout
makes it a pure non-blocking check.

Caveats worth knowing:

- **Delivery happens only between transactions** — keep the listening
  connection out of transactions and out of pools.
- **Subscriptions do not survive reconnect.** On a dead connection
  (`conn.status() != CONNECTION_OK`), build a fresh `Connection` and re-issue
  `listen()` for every channel (peque deliberately has no `PQreset` wrapper).
- The server **deduplicates identical `(channel, payload)`** notifications
  sent within one transaction.
- Payloads are limited to **~8000 bytes** — send an ID, not a document.
- `waitNotifications` requires the connection's `WaitStrategy` to provide the
  optional timed overload `bool wait(int fd, WaitMask mask, Duration timeout)`.
  `PollWaitStrategy` (default) and `VibeWaitStrategy` both do; a custom
  strategy without it keeps working for queries and `getNotifications()`.

---

## Running tests

Integration tests require a running PostgreSQL instance. Configure via
environment variables (defaults shown):

```sh
POSTGRES_DB=peque-test \
POSTGRES_USER=peque \
POSTGRES_PASSWORD=peque \
POSTGRES_HOST=localhost \
POSTGRES_PORT=5432 \
dub test --config=unittestStatic
```

Sub-package tests:

```sh
dub test :orm     --config=unittestStatic
dub test :migrate --config=unittestStatic
```

## License

[Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/)
