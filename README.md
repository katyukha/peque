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

## Supported types

| D type | PostgreSQL type |
|---|---|
| `string` | `text`, `varchar`, `char`, … |
| `JSONValue` | `json`, `jsonb` |
| `int`, `long`, `short` | `integer`, `bigint`, `smallint` |
| `float`, `double` | `real`, `double precision` |
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

Business logic functions take `ref Transaction` and are completely unaware of
nesting depth:

```d
void deductStock(ref Transaction tx, string item, int qty) {
    tx.execParams(
        "UPDATE items SET qty = qty - $1 WHERE name = $2", qty, item);
}

c.transaction((ref tx) { deductStock(tx, "apple", 1); });
```

### Savepoints

`Transaction.savepoint()` creates a PostgreSQL savepoint. On exception, only
the savepoint changes are rolled back — the enclosing transaction remains open
and intact. The delegate receives the same `ref Transaction`, so the same
business logic functions work at any nesting depth without modification.

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

Savepoints can be nested arbitrarily. `OnSuccess.rollback` works on savepoints
too — useful for dry-run sub-operations inside a larger transaction.

### Isolation levels

The `IsolationLevel` template parameter controls the PostgreSQL transaction
isolation level. The default is `readCommitted`, which is always set
**explicitly** in the `BEGIN` statement regardless of server configuration —
so the behaviour is predictable even if the server or role has a different
`default_transaction_isolation` configured.

```d
import peque;

// Read committed (default) — explicit in BEGIN, immune to server config
c.transaction((ref tx) { ... });

// Repeatable read
c.transaction!(OnSuccess.commit, IsolationLevel.repeatableRead)((ref tx) { ... });

// Serializable — may throw on conflict, application must be prepared to retry
c.transaction!(OnSuccess.commit, IsolationLevel.serializable)((ref tx) { ... });

// Server default — emits plain BEGIN, defers to postgresql.conf / ALTER ROLE / ALTER DATABASE
c.transaction!(OnSuccess.commit, IsolationLevel.serverDefault)((ref tx) { ... });
```

| Value | BEGIN emitted | Notes |
|---|---|---|
| `readCommitted` (default) | `BEGIN ISOLATION LEVEL READ COMMITTED` | Predictable regardless of server config |
| `repeatableRead` | `BEGIN ISOLATION LEVEL REPEATABLE READ` | |
| `serializable` | `BEGIN ISOLATION LEVEL SERIALIZABLE` | May abort; application must retry |
| `serverDefault` | `BEGIN` | Respects server/role/database configuration |

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

## License

[Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/)
