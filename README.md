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
- **`peque:migrate`** — compile-time D-struct migration runner with rollback and opt-in checksum pinning
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
    "peque": "~>0.2.0"
}
```

`dub.sdl`:
```
dependency "peque" version="~>0.2.0"
```

Sub-packages are opt-in. Note that `peque:orm` and `peque:migrate` are not part
of any tagged release yet — they land in the next one; until then depend on the
repository directly if you want them:

```
dependency "peque:orm"     version="~>0.2.0"   // ORM layer
dependency "peque:migrate" version="~>0.2.0"   // migration runner
dependency "peque:vibe"    version="~>0.2.0"   // vibe.d integration
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

### Identifier quoting

Every identifier peque emits — table, column, junction table and its keys,
constraint names — is double-quoted in the generated SQL. That means a field
called `order`, `end`, `user` or `check` just works, with no keyword list to
fall out of date as PostgreSQL reserves new words:

```d
@model("order")                       // reserved word, fine
struct Order {
    @primaryKey int    id;
    @field      string check;         // reserved word, fine
    @field      int    end;           // reserved word, fine
}
// CREATE TABLE IF NOT EXISTS "order" ("id" SERIAL PRIMARY KEY, "check" TEXT …)
```

The consequence to know: **quoted identifiers are case-exact**, so the string
you write in `@model`/`@field` *is* the identifier. For the usual snake_case
model that changes nothing, since `"email_address"` and a bare `email_address`
address the same column. It matters when mapping a table you did not create:

```sql
-- Written by someone else, unquoted, so PostgreSQL folded it to lowercase:
CREATE TABLE SaleOrder (OrderDate date);   -- actually stored as saleorder / orderdate
```

```d
@model("saleorder")                        // the folded name, not "SaleOrder"
struct SaleOrder {
    @field("orderdate") Date orderDate;
}
```

Getting this wrong fails loudly with `column "OrderDate" does not exist` rather
than silently reading the wrong data. peque's own synthetic identifiers — table
aliases, joined-column aliases, generated index names — are left unquoted, since
they cannot collide with a keyword.

### Column defaults

peque's `insert` always names **every** column and binds the D field's value.
That has one consequence worth knowing before you reach for `@pgDefault`: a
database-level `DEFAULT` never fires on the peque path, because peque always
supplies a value for the column.

So a default belongs in one of three places, depending on what it is:

| Kind of default | Where it goes |
|---|---|
| Compile-time constant | a D field initialiser — `bool active = true;` |
| Computed per insert | `applyDefaults()` on the model |
| Database-level only | `@pgDefault("…")` |

```d
@model("res_partner")
struct Partner {
    @primaryKey int     id;
    @field      string  name;
    @field      bool    active = true;      // sent on every insert
    @field      SysTime createdAt;

    // Runtime values: called by insert() before the row is written.
    void applyDefaults() {
        if (createdAt == SysTime.init) createdAt = Clock.currTime;
    }
}
```

`@pgDefault` is a **schema declaration**, not an insert behaviour. It puts a
`DEFAULT` in the generated DDL for the benefit of other applications writing to
the table, a later `ALTER TABLE … ADD COLUMN`, and anyone reading the schema —
peque itself overrides it every time.

The trap that follows from this:

```d
@field @pgDefault("now()") SysTime createdAt;   // does NOT give you now()
```

peque sends `SysTime.init`, so the row gets year 1 rather than the server's
clock. Use `applyDefaults` for that, and treat `@pgDefault` as documentation of
what the *database* does when someone else inserts.

(This mirrors how SQLAlchemy splits `default=` from `server_default=`, and
Django `default=` from `db_default=` — a client-side default and a
database-side default are different features.)

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

// Upsert by natural key — conflict on any UNIQUE column(s).
// The target column must actually carry a unique constraint, or PostgreSQL
// rejects the ON CONFLICT clause. For the model above that means:
//     @field @unique string email;
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

// Delete matching rows — returns count deleted.
// delete_()/update() affect exactly the rows all() would return, including
// relation-path predicates like F!"partner.name".isNull (LEFT JOIN semantics).
long deleted = repo.query().where!"active"(false).delete_();

// Without a where() these affect EVERY row — there is no truncation guard.
// repo.query().delete_() empties the table; make sure that is what you meant.
// Neither accepts limit()/offset(): PostgreSQL has no row bound on DELETE or
// UPDATE, so peque rejects the combination rather than silently ignoring it.

// Partial update — set only named fields
long updated = repo.query()
    .where!"active"(false)
    .set!"name"("Archived")
    .update();

// none() — force empty result (useful when building conditional filters)
auto qs = allowedIds.empty ? repo.query().none()
                           : repo.query().whereIn!"id"(allowedIds);

// select!DTO() — project into a different struct.
// The DTO needs @autoHydrate (or @model) so its fields can be mapped.
@autoHydrate
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
`_sq` alias and throw `NotSupportedError` at serialisation time.

### IN subqueries

`asSubquery!"field"()` captures a QuerySet as a single-column subquery atom
without hitting the database. Pass it to `F!(M,"field").inSubquery()` for
`IN (SELECT …)`, or negate with `~` for `NOT IN`. The subquery keeps the
QuerySet's ORDER BY (explicit or `@defaultOrder`), so
`orderBy(F!"amount".desc).limit(5).asSubquery!"id"()` really is "ids of the
top 5 by amount", not 5 arbitrary rows.

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

`up()`/`down()` take `ref Transaction`: each migration runs inside its own
transaction together with the row that records it, so the two commit or roll back
as one. `ref Connection` is still accepted for compatibility, but it lets a
migration end that transaction early and break the guarantee.

```d
import peque;
import peque.migrate;

struct V1_CreateUsers {
    enum description = "create users table";
    void up(ref Transaction tx) {
        tx.exec(`CREATE TABLE users (
            id    serial PRIMARY KEY,
            name  text   NOT NULL,
            email text   NOT NULL DEFAULT ''
        )`);
    }
    void down(ref Transaction tx) {
        tx.exec(`DROP TABLE users`);
    }
}

struct V2_AddIndex {
    enum description = "index users.email";
    void up(ref Transaction tx) {
        tx.exec(`CREATE INDEX ON users (email)`);
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

Checksums are **opt-in**. A migration that declares one:

```d
struct M3_AddIndex {
    enum description = "index sale_order.partner_id";
    enum checksum    = "2024-06-01a";   // bump when the SQL below changes
    void up(ref Transaction tx) { tx.exec("CREATE INDEX ..."); }
}
```

has that value stored on first apply, and any later run — `migrate()` **or**
`rollback()` — throws `MigrationError` if the declared value no longer matches
what the database recorded.

The checksum is a value *you* declare, not a hash of the SQL: `up()` is ordinary
D code and D offers no way to read a function body, so peque cannot compute one
for you. Bump it whenever you change the migration's effect. A migration that
declares no checksum is simply not checked, which means renaming its module or
struct, or editing its description, can never brick a deployed database.

### Migrations the runner refuses to run

`migrate()`, `status()` and `rollback()` all reject a database state the compiled
list cannot describe:

- a recorded version beyond the end of the list — the database was migrated by a
  newer build, so this one would mis-attribute versions;
- a gap, e.g. v2 recorded while v1 is not — since versions are list positions,
  that means the list was reordered or extended in the middle, and applying the
  missing one now would run it out of order.

### Statements that cannot run in a transaction

Each migration runs inside its own transaction. For statements PostgreSQL refuses
there — `CREATE INDEX CONCURRENTLY`, `ALTER TYPE ... ADD VALUE` — opt out:

```d
struct M4_ConcurrentIndex {
    enum description   = "concurrent index";
    enum transactional = false;
    void up(ref Connection conn) {
        conn.exec("CREATE INDEX CONCURRENTLY ... ");
    }
}
```

Such a migration is not atomic with its own bookkeeping row, so write it
idempotently (`IF NOT EXISTS`): a crash between the two leaves the change applied
but unrecorded, and the next run retries it.

---

## vibe.d (`peque:vibe`)

`peque:vibe` provides a fiber-aware wait strategy and connection pool for
vibe.d applications. Instead of blocking the OS thread while waiting for
PostgreSQL, control yields to the vibe.d event loop.

```d
dependency "peque:vibe" version="~>0.2.0"
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

## Error handling

Every peque exception derives from `PequeException`, and each carries structured
fields — acting on an error never requires parsing its message. That matters
because PostgreSQL localises its messages via `lc_messages`, which a
non-superuser cannot override, so text matching is unsound in principle.

```
PequeException                  root — never thrown directly
├── ConnectionError             the link is unusable
├── NotSupportedError           peque will not do this, in any context
├── ConversionError             a value could not be converted, either direction
├── QueryError                  category — scoped to running a query
│   ├── QueryClientError        your call is wrong
│   │   └── QueryEscapingError  …an identifier/JSON key that cannot be escaped
│   └── QueryServerError        PostgreSQL rejected it — carries SQLSTATE
│       ├── IntegrityError      SQLSTATE class 23
│       └── SerializationError  SQLSTATE class 40
└── ResultError                 the result has no such row or column
    ├── RowNotExistsError
    └── ColNotExistsError
```

### Constraint violations

`QueryServerError` carries the backend's diagnostics, captured as the exception
is built — the underlying result is freed while the stack unwinds, so they
cannot be read afterwards.

```d
try {
    repo.insert(user);
} catch (IntegrityError e) {
    final switch (e.kind) {
        case IntegrityKind.unique:     return conflict(e.constraintName);
        case IntegrityKind.foreignKey: return badReference(e.constraintName);
        case IntegrityKind.notNull:    return missingField(e.columnName);
        case IntegrityKind.check:
        case IntegrityKind.exclusion:
        case IntegrityKind.restrict:
        case IntegrityKind.other:      return unprocessable(e.messagePrimary);
    }
}
```

Which fields the server populates depends on the violation, and the asymmetry is
PostgreSQL's, not peque's:

| SQLSTATE | violation | `constraintName` | `columnName` |
|---|---|:--:|:--:|
| 23502 | not null | — | ✓ |
| 23503 | foreign key | ✓ | — |
| 23505 | unique | ✓ | — |

For unique and foreign-key violations the offending columns appear only inside
the localised `DETAIL` text, which peque deliberately does not parse. Map the
constraint name to your own fields instead. A field the server did not supply is
an empty string.

### Retrying

Retry-ability cuts across SQLSTATE classes, so it is a predicate rather than a
branch of the tree:

```d
foreach (attempt; 0 .. 3) {
    try {
        conn.transaction!(OnSuccess.commit, IsolationLevel.serializable)((ref tx) { … });
        break;
    } catch (QueryServerError e) {
        if (!e.isRetriable() || attempt == 2) throw e;
    } catch (ConnectionError e) {
        // The link is gone, so this needs a fresh connection rather than a
        // replay on the same one — take one from the pool before retrying.
        if (attempt == 2) throw e;
    }
}
```

`ConnectionError` is a sibling of `QueryError`, not a subclass, so a loop that
catches only `QueryServerError` will not see a dropped connection.

`isRetriable()` covers serialization failures, deadlocks and lock timeouts,
which can be retried on the same connection, plus connection-class failures,
which need a fresh one. Codes with an unknown outcome — `40003`, and `57014`
for a cancellation you requested — are deliberately excluded.

`sqlstate` is always populated on a `QueryServerError`, and the exception type is
chosen from the SQLSTATE *class*, never the full code — so an unrecognised
class-23 code still arrives as an `IntegrityError` with `kind == other` rather
than falling back to the base type.

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
