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
private import peque.connection: Connection;
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
    c.execParams(`DELETE FROM schema_versions WHERE namespace = $1`, ns);
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
    auto m = Migrator!(TestMigs)(&c, "mig_test_cs");

    m.migrate();

    // Corrupt the stored checksum for v1 to simulate an edited migration.
    c.execParams(
        `UPDATE schema_versions SET checksum = 'deadbeef' WHERE namespace = $1 AND version = $2`,
        "mig_test_cs", 1,
    );

    assertThrown!MigrationError(m.migrate());
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
    c.execParams(`DELETE FROM schema_versions WHERE namespace = $1`, "mig_test_fail");

    alias FailMigs = MigrationList!(M1_CreateFoo, M_Fail);
    auto m = Migrator!(FailMigs)(&c, "mig_test_fail");

    // The second migration throws — the whole migrate() must propagate the error.
    assertThrown!QueryError(m.migrate());

    // M1 was applied before the failure and committed in its own transaction.
    auto st = m.status();
    assert(st.length == 2);
    assert( st[0].applied, "M1 committed before the failing migration must remain applied");
    assert(!st[1].applied, "failed migration must not be recorded in schema_versions");
}
