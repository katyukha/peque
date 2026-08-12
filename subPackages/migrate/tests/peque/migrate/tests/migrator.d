/** Integration tests for peque:migrate — Migrator and MigrationList.
  *
  * Covers:
  *  - migrate() applies all pending migrations
  *  - migrate() is idempotent (second call is a no-op)
  *  - status() returns correct applied/pending information
  *  - status() after partial apply shows correct mixed state
  *  - rollback(n) rolls back the last n applied migrations
  *  - rollback(n > 1) rolls back multiple migrations in reverse order
  *  - rollback() when nothing is applied is a no-op
  *  - rollback() on a migration without down() throws MigrationError
  *  - checksum mismatch on an already-applied migration throws MigrationError
  *  - two namespaces are fully independent on the same connection
  **/
module peque.migrate.tests.migrator;

private import std.process: environment;
private import std.exception: assertThrown;
private import std.conv: to;
private import peque.connection: Connection, Transaction;
private import peque.migrate;


// ---------------------------------------------------------------------------
// Test migrations
// ---------------------------------------------------------------------------

struct M1_CreateFoo {
    enum description = "create mig_foo table";
    void up(ref Connection conn) {
        conn.exec(`CREATE TABLE IF NOT EXISTS mig_foo (
            id   serial PRIMARY KEY,
            name text   NOT NULL
        )`);
    }
    void down(ref Connection conn) {
        conn.exec(`DROP TABLE IF EXISTS mig_foo`);
    }
}

struct M2_AddBar {
    enum description = "add bar column to mig_foo";
    void up(ref Connection conn) {
        conn.exec(`ALTER TABLE mig_foo ADD COLUMN IF NOT EXISTS bar text NOT NULL DEFAULT ''`);
    }
    void down(ref Connection conn) {
        conn.exec(`ALTER TABLE mig_foo DROP COLUMN IF EXISTS bar`);
    }
}

struct M3_NoDown {
    enum description = "irreversible migration";
    void up(ref Connection conn) {
        conn.exec(`CREATE TABLE IF NOT EXISTS mig_baz (id serial PRIMARY KEY)`);
    }
    // intentionally no down()
}

alias TestMigs   = MigrationList!(M1_CreateFoo, M2_AddBar);
alias TestMigs3  = MigrationList!(M1_CreateFoo, M2_AddBar, M3_NoDown);


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

private void cleanup(ref Connection c, string ns) {
    import peque.migrate.version_table: ensureVersionTable;
    c.exec(`DROP TABLE IF EXISTS mig_foo`);
    c.exec(`DROP TABLE IF EXISTS mig_baz`);
    ensureVersionTable(c);
    c.execParams(`DELETE FROM __peque_migrations WHERE namespace = $1`, ns);
}


// ---------------------------------------------------------------------------
// migrate() applies all pending
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test1");
    auto m = Migrator!(TestMigs)(&c, "mig_test1");

    m.migrate();

    auto st = m.status();
    assert(st.length == 2);
    assert(st[0].applied);
    assert(st[1].applied);
    assert(st[0].description == "create mig_foo table");
    assert(st[1].description == "add bar column to mig_foo");
}


// ---------------------------------------------------------------------------
// migrate() is idempotent
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test2");
    auto m = Migrator!(TestMigs)(&c, "mig_test2");

    m.migrate();
    m.migrate();  // must be a no-op

    auto st = m.status();
    foreach (s; st) assert(s.applied);
}


// ---------------------------------------------------------------------------
// status() before any migration: all pending
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test3");
    auto m = Migrator!(TestMigs)(&c, "mig_test3");

    auto st = m.status();
    assert(st.length == 2);
    foreach (s; st) {
        assert(!s.applied);
        assert(s.appliedAt == "");
    }
}


// ---------------------------------------------------------------------------
// rollback(1) undoes the last migration
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test4");
    auto m = Migrator!(TestMigs)(&c, "mig_test4");

    m.migrate();
    m.rollback(1);

    auto st = m.status();
    assert(st.length == 2);
    assert( st[0].applied);   // M1 still applied
    assert(!st[1].applied);   // M2 rolled back
}


// ---------------------------------------------------------------------------
// rollback(n) on missing down() throws MigrationError
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test5");
    auto m = Migrator!(TestMigs3)(&c, "mig_test5");

    m.migrate();  // applies M1, M2, M3

    // M3 has no down() — rollback must throw
    assertThrown!MigrationError(m.rollback(1));
}


// ---------------------------------------------------------------------------
// status() after partial apply: mixed applied/pending
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_partial");

    // Apply only M1 by using a single-migration list first, then check
    // full status via the two-migration Migrator.
    alias PartialMigs = MigrationList!(M1_CreateFoo);
    Migrator!(PartialMigs)(&c, "mig_test_partial").migrate();

    auto st = Migrator!(TestMigs)(&c, "mig_test_partial").status();
    assert(st.length == 2);
    assert( st[0].applied);
    assert(!st[1].applied);
    assert(st[0].appliedAt != "");
    assert(st[1].appliedAt == "");
}


// ---------------------------------------------------------------------------
// rollback(2) rolls back two migrations in reverse order
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_rb2");
    auto m = Migrator!(TestMigs)(&c, "mig_test_rb2");

    m.migrate();
    m.rollback(2);

    auto st = m.status();
    assert(st.length == 2);
    assert(!st[0].applied);
    assert(!st[1].applied);
}


// ---------------------------------------------------------------------------
// rollback() when nothing is applied is a no-op
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_rb0");
    auto m = Migrator!(TestMigs)(&c, "mig_test_rb0");

    m.rollback(1);  // nothing applied — must not throw

    auto st = m.status();
    foreach (s; st) assert(!s.applied);
}


// ---------------------------------------------------------------------------
// checksum mismatch throws MigrationError
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_cs");
    auto m = Migrator!(CsMigs)(&c, "mig_test_cs");

    m.migrate();

    // Corrupt the stored checksum for v1 to simulate an edited migration.
    c.execParams(
        `UPDATE __peque_migrations SET checksum = 'deadbeef' WHERE namespace = $1 AND version = $2`,
        "mig_test_cs", 1,
    );

    assertThrown!MigrationError(m.migrate());
    // rollback() used to skip checksum validation entirely, so down() ran
    // against state the runner had never verified.
    assertThrown!MigrationError(m.rollback(1));
}

// A migration that declares no checksum is not validated, so renaming it or
// editing its description can never brick a deployed database.
unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_nocs");
    auto m = Migrator!(TestMigs)(&c, "mig_test_nocs");

    m.migrate();
    c.execParams(
        `UPDATE __peque_migrations SET checksum = 'whatever' WHERE namespace = $1`,
        "mig_test_nocs",
    );
    m.migrate();                      // must not throw
    assert(m.status()[0].applied);
}


// ---------------------------------------------------------------------------
// Two namespaces are independent
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_ns_a");
    cleanup(c, "mig_ns_b");

    auto ma = Migrator!(TestMigs)(&c, "mig_ns_a");
    auto mb = Migrator!(TestMigs)(&c, "mig_ns_b");

    ma.migrate();

    // ma: all applied, mb: all pending
    foreach (s; ma.status()) assert( s.applied);
    foreach (s; mb.status()) assert(!s.applied);

    mb.migrate();

    foreach (s; ma.status()) assert(s.applied);
    foreach (s; mb.status()) assert(s.applied);
}


// ---------------------------------------------------------------------------
// rollback(n > applied_count) — must roll back all applied, not throw
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_test_rb_excess");
    auto m = Migrator!(TestMigs)(&c, "mig_test_rb_excess");

    m.migrate();  // applies M1 + M2

    // Requesting 10 rollbacks when only 2 are applied must silently roll back
    // all 2 and not throw.
    m.rollback(10);

    auto st = m.status();
    assert(st.length == 2);
    assert(!st[0].applied, "M1 must be rolled back");
    assert(!st[1].applied, "M2 must be rolled back");
}


// ---------------------------------------------------------------------------
// migrate() failure mid-list: failing up() is rolled back, migration not recorded
// ---------------------------------------------------------------------------

struct M_Fail {
    enum description = "always fails";
    void up(ref Connection conn) {
        // Deliberately invalid SQL so PostgreSQL rejects it.
        conn.exec("THIS IS NOT VALID SQL @@@@");
    }
    void down(ref Connection conn) {
        // nothing to undo — up() never succeeded
    }
}

unittest {
    import std.exception: assertThrown;
    import peque.exception: QueryError;

    auto c = makeConn();
    cleanup(c, "mig_test_fail");
    c.exec(`DROP TABLE IF EXISTS mig_foo`);
    c.exec(`DROP TABLE IF EXISTS mig_baz`);
    c.execParams(`DELETE FROM __peque_migrations WHERE namespace = $1`, "mig_test_fail");

    alias FailMigs = MigrationList!(M1_CreateFoo, M_Fail);
    auto m = Migrator!(FailMigs)(&c, "mig_test_fail");

    // The second migration throws — the whole migrate() must propagate the error.
    assertThrown!QueryError(m.migrate());

    // M1 was applied before the failure and committed in its own transaction.
    auto st = m.status();
    assert(st.length == 2);
    assert( st[0].applied, "M1 committed before the failing migration must remain applied");
    assert(!st[1].applied, "failed migration must not be recorded in __peque_migrations");
}


// ---------------------------------------------------------------------------
// Migrations used by the checksum tests — these opt in via `enum checksum`
// ---------------------------------------------------------------------------

struct CsM1 {
    enum description = "checksummed create";
    enum checksum    = "cs-v1";
    void up(ref Transaction tx)   { tx.exec(`CREATE TABLE IF NOT EXISTS mig_cs (id serial PRIMARY KEY)`); }
    void down(ref Transaction tx) { tx.exec(`DROP TABLE IF EXISTS mig_cs`); }
}
alias CsMigs = MigrationList!(CsM1);


// ---------------------------------------------------------------------------
// up(ref Transaction) is preferred over up(ref Connection)
// ---------------------------------------------------------------------------

// Passing the raw Connection let a migration COMMIT out of the transaction that
// was supposed to make up-SQL and the bookkeeping insert atomic. Transaction
// deliberately exposes no commit/rollback, so taking it closes that hole.
struct TxM1 {
    enum description = "transaction-scoped migration";
    void up(ref Transaction tx) {
        tx.exec(`CREATE TABLE IF NOT EXISTS mig_tx (id serial PRIMARY KEY)`);
    }
    void down(ref Transaction tx) {
        tx.exec(`DROP TABLE IF EXISTS mig_tx`);
    }
}
alias TxMigs = MigrationList!(TxM1);

// Transaction.commit/rollback are package(peque), so a migration written in an
// application module cannot end the transaction early. That cannot be asserted
// from here — this test module is itself inside the peque package — so the
// property under test is the one that matters in practice: up() really does run
// inside the transaction that also records the migration.
struct TxFailM {
    enum description = "creates a table then fails";
    void up(ref Transaction tx) {
        tx.exec(`CREATE TABLE mig_tx_rollback (id serial PRIMARY KEY)`);
        throw new Exception("boom");
    }
}
alias TxFailMigs = MigrationList!(TxFailM);

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS mig_tx_rollback`);
    cleanup(c, "mig_tx_fail");

    auto m = Migrator!(TxFailMigs)(&c, "mig_tx_fail");
    assertThrown!Exception(m.migrate());

    // Both halves rolled back together: no table, and nothing recorded.
    assert(!c.exec(`SELECT to_regclass('mig_tx_rollback') IS NOT NULL`).getValue!bool(0, 0),
        "up() must run inside the transaction that records the migration");
    assert(!m.status()[0].applied);
}

unittest {
    auto c = makeConn();
    c.exec(`DROP TABLE IF EXISTS mig_tx`);
    cleanup(c, "mig_tx_ns");

    auto m = Migrator!(TxMigs)(&c, "mig_tx_ns");
    m.migrate();
    assert(m.status()[0].applied);
    assert(c.exec(`SELECT to_regclass('mig_tx') IS NOT NULL`).getValue!bool(0, 0));

    m.rollback(1);
    assert(!m.status()[0].applied);
    assert(!c.exec(`SELECT to_regclass('mig_tx') IS NOT NULL`).getValue!bool(0, 0));
}


// ---------------------------------------------------------------------------
// enum transactional = false — statements PostgreSQL refuses inside a block
// ---------------------------------------------------------------------------

struct NonTxM1 {
    enum description   = "create table for concurrent index";
    void up(ref Transaction tx) {
        tx.exec(`CREATE TABLE IF NOT EXISTS mig_conc (id serial PRIMARY KEY, name text)`);
    }
    void down(ref Transaction tx) { tx.exec(`DROP TABLE IF EXISTS mig_conc`); }
}

struct NonTxM2 {
    enum description   = "concurrent index";
    enum transactional = false;      // CREATE INDEX CONCURRENTLY cannot run in a transaction
    void up(ref Connection conn) {
        conn.exec(`CREATE INDEX CONCURRENTLY IF NOT EXISTS mig_conc_name_idx ON mig_conc (name)`);
    }
    void down(ref Connection conn) { conn.exec(`DROP INDEX IF EXISTS mig_conc_name_idx`); }
}
alias NonTxMigs = MigrationList!(NonTxM1, NonTxM2);

unittest {
    auto c = makeConn();
    c.exec(`DROP INDEX IF EXISTS mig_conc_name_idx`);
    c.exec(`DROP TABLE IF EXISTS mig_conc`);
    cleanup(c, "mig_conc_ns");

    auto m = Migrator!(NonTxMigs)(&c, "mig_conc_ns");
    // Before the opt-out this failed with "CREATE INDEX CONCURRENTLY cannot run
    // inside a transaction block".
    m.migrate();

    foreach (s; m.status()) assert(s.applied);
    assert(c.exec(`SELECT to_regclass('mig_conc_name_idx') IS NOT NULL`).getValue!bool(0, 0));

    c.exec(`DROP INDEX IF EXISTS mig_conc_name_idx`);
    c.exec(`DROP TABLE IF EXISTS mig_conc`);
}


// ---------------------------------------------------------------------------
// Database states the compiled list cannot describe
// ---------------------------------------------------------------------------

unittest {
    auto c = makeConn();
    cleanup(c, "mig_gap");

    // A gap: v2 applied while v1 is not. With position-based versioning this
    // means the list was reordered or grown in the middle; migrate() used to
    // silently apply v1 *after* v2.
    c.execParams(
        `INSERT INTO __peque_migrations (namespace, version, description, checksum)
         VALUES ($1, 2, 'out of order', '')`,
        "mig_gap",
    );
    auto m = Migrator!(TestMigs)(&c, "mig_gap");
    assertThrown!MigrationError(m.migrate());
    assertThrown!MigrationError(m.status());
    assertThrown!MigrationError(m.rollback(1));

    // A version beyond the compiled list: the database was migrated by a newer
    // build. Previously invisible to migrate()/status(), and rollback() counted
    // it as rolled back without doing anything.
    cleanup(c, "mig_newer");
    c.execParams(
        `INSERT INTO __peque_migrations (namespace, version, description, checksum)
         VALUES ($1, 1, 'a', ''), ($1, 2, 'b', ''), ($1, 99, 'from the future', '')`,
        "mig_newer",
    );
    auto m2 = Migrator!(TestMigs)(&c, "mig_newer");
    assertThrown!MigrationError(m2.migrate());
    assertThrown!MigrationError(m2.status());
    assertThrown!MigrationError(m2.rollback(1));

    cleanup(c, "mig_gap");
    cleanup(c, "mig_newer");
}


// ---------------------------------------------------------------------------
// Two Migrators racing the advisory lock (long-standing test gap)
// ---------------------------------------------------------------------------

unittest {
    import core.thread: Thread;

    auto setup = makeConn();
    setup.exec(`DROP TABLE IF EXISTS mig_foo`);
    cleanup(setup, "mig_race");
    // Drop the tracking table too, so both threads race to create it as well —
    // that creation now happens under the lock rather than before it.
    setup.exec(`DROP TABLE IF EXISTS __peque_migrations`);

    shared string[] failures;
    void runOne() {
        try {
            auto conn = makeConn();
            auto m    = Migrator!(TestMigs)(&conn, "mig_race");
            m.migrate();
        } catch (Exception e) {
            synchronized { failures ~= e.msg; }
        }
    }

    auto threads = new Thread[4];
    foreach (ref t; threads) t = new Thread(&runOne);
    foreach (t; threads) t.start();
    foreach (t; threads) t.join();

    assert(failures.length == 0,
        "concurrent migrate() raced: " ~ (failures.length ? failures[0] : ""));

    // Exactly one row per migration — no duplicates from the race.
    auto check = makeConn();
    auto n = check.execParams(
        `SELECT COUNT(*) FROM __peque_migrations WHERE namespace = $1`, "mig_race")
        .getValue!long(0, 0);
    assert(n == 2, "expected 2 recorded migrations, got " ~ n.to!string);

    auto m = Migrator!(TestMigs)(&check, "mig_race");
    foreach (s; m.status()) assert(s.applied);
}
