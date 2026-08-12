module peque.migrate.migrator;

private import std.format: format;
private import peque.connection: Connection, Transaction;
private import peque.migrate.version_table;

class MigrationError : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// Compile-time migration list — version = 1-based position, never reorder.
//
// MigrationList is a transparent AliasSeq alias: Migrator!(MigrationList!(M1, M2))
// and Migrator!(M1, M2) are identical types. The wrapper is purely documentary —
// it signals intent at the call site without any runtime overhead.
template MigrationList(Migrations...) {
    alias MigrationList = Migrations;
}

struct MigrationStatus {
    int    version_;
    string description;
    bool   applied;
    string appliedAt;  // ISO timestamp string, empty when not applied
}

/** Runner for a compile-time list of migration structs.
  *
  * A migration is a struct with:
  *   void up(ref Transaction tx)      — required (ref Connection also accepted)
  *   void down(ref Transaction tx)    — optional; required to rollback
  *   enum description = "..."         — optional; defaults to the struct name
  *   enum checksum    = "..."         — optional; see _migrationChecksum
  *   enum transactional = false       — optional; opt out of the wrapping
  *                                      transaction for statements PostgreSQL
  *                                      refuses inside one (CREATE INDEX
  *                                      CONCURRENTLY, ALTER TYPE ... ADD VALUE)
  **/
struct Migrator(Migrations...)
if (Migrations.length > 0) {
    private Connection* _conn;
    private string      _namespace;

    this(Connection* conn, string namespace) {
        _conn      = conn;
        _namespace = namespace;
    }

    // Apply all pending migrations. Each migration runs in its own transaction
    // unless it opts out with `enum transactional = false`.
    //
    // The advisory lock is taken FIRST — before the version table is created or
    // read. Creating it under CREATE TABLE IF NOT EXISTS is not safe against a
    // concurrent creator (PostgreSQL can still raise a duplicate-key error on
    // pg_type), so the lock has to cover that too.
    void migrate() {
        _withLock({
            ensureVersionTable(*_conn);
            auto applied = loadApplied(*_conn, _namespace);
            _checkAppliedIntegrity(applied);
            _validateChecksums(applied);

            auto appliedSet = _appliedSet(applied);

            static foreach (i, M; Migrations) {{
                enum ver = cast(int)(i + 1);
                if (ver !in appliedSet)
                    _applyOne!M(ver);
            }}
        });
    }

    // Return applied/pending status for every migration in the list.
    MigrationStatus[] status() {
        ensureVersionTable(*_conn);
        auto applied = loadApplied(*_conn, _namespace);
        _checkAppliedIntegrity(applied);

        string[int] appliedAt;
        foreach (a; applied) appliedAt[a.version_] = a.appliedAt;

        MigrationStatus[] result;
        static foreach (i, M; Migrations) {{
            enum ver = cast(int)(i + 1);
            auto when = ver in appliedAt;
            result ~= MigrationStatus(ver, _migrationDesc!M(),
                                      when !is null, when ? *when : "");
        }}
        return result;
    }

    // Roll back the last n applied migrations (reverse order). Requires down().
    void rollback(int n = 1) {
        if (n <= 0) return;

        _withLock({
            ensureVersionTable(*_conn);
            auto applied = loadApplied(*_conn, _namespace);
            if (applied.length == 0) return;

            _checkAppliedIntegrity(applied);
            // migrate() validated twice and rollback not at all, so down() from
            // an edited migration used to run against unverified state.
            _validateChecksums(applied);

            int rolled = 0;
            foreach_reverse (a; applied) {
                if (rolled >= n) break;
                _rollbackOne(a.version_);
                rolled++;
            }
        });
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    // Run body under the namespace's session advisory lock.
    private void _withLock(scope void delegate() body_) {
        immutable lockKey = _advisoryKey(_namespace);

        // A failing unlock must not replace the exception that is already
        // unwinding — on a dead connection both throw, and the second one would
        // bury the root cause. Session locks die with the session anyway, so
        // dropping this error loses nothing.
        void unlockQuietly() {
            try
                _conn.execParams("SELECT pg_advisory_unlock($1::bigint)", lockKey);
            catch (Exception) { }
        }

        _conn.execParams("SELECT pg_advisory_lock($1::bigint)", lockKey);
        scope(exit) unlockQuietly();
        body_();
    }

    private void _applyOne(M)(int ver) {
        enum transactional = !__traits(hasMember, M, "transactional") ||
                             M.transactional;
        static if (transactional) {
            _conn.transaction((ref Transaction tx) {
                M m;
                _runUp!M(m, tx);
                recordMigration(*_conn, _namespace, ver,
                                _migrationDesc!M(), _migrationChecksum!M());
            });
        } else {
            // Opted out: the statement cannot run inside a transaction block, so
            // up() and the bookkeeping insert are not atomic together. A crash
            // between them leaves the change applied but unrecorded, which the
            // next run would retry — write such migrations idempotently.
            M m;
            m.up(*_conn);
            recordMigration(*_conn, _namespace, ver,
                            _migrationDesc!M(), _migrationChecksum!M());
        }
    }

    // Prefer up(ref Transaction): passing the Connection let a migration call
    // conn.exec("COMMIT") and escape the atomicity guard that wraps it.
    // up(ref Connection) is still accepted so existing migrations keep working.
    private void _runUp(M)(ref M m, ref Transaction tx) {
        static if (__traits(compiles, m.up(tx)))
            m.up(tx);
        else
            m.up(*_conn);
    }

    private void _runDown(M)(ref M m, ref Transaction tx) {
        static if (__traits(compiles, m.down(tx)))
            m.down(tx);
        else
            m.down(*_conn);
    }

    private void _rollbackOne(int ver) {
        bool handled = false;
        static foreach (i, M; Migrations) {{
            if (!handled && cast(int)(i + 1) == ver) {
                handled = true;
                static if (__traits(hasMember, M, "down")) {
                    _conn.transaction((ref Transaction tx) {
                        M m;
                        _runDown!M(m, tx);
                        removeMigration(*_conn, _namespace, ver);
                    });
                } else {
                    throw new MigrationError(format!(
                        "Migration %s (v%d) has no down() — cannot rollback"
                    )(_migrationName!M(), ver));
                }
            }
        }}
        // _checkAppliedIntegrity already rejects out-of-range versions, so this
        // is a belt-and-braces guard: the previous code let an unknown version
        // fall through silently and still counted it as rolled back.
        if (!handled)
            throw new MigrationError(format!(
                "Applied version %d is not in the compiled migration list " ~
                "(%d migrations) — cannot roll it back."
            )(ver, cast(int)Migrations.length));
    }

    /** Reject a database state the compiled list cannot describe.
      *
      * Two cases, both silent before:
      *  - a version beyond the end of the list: the database was migrated by a
      *    newer build, and running this one would mis-attribute versions;
      *  - a gap: version N applied while some earlier version is not. With
      *    position-based versioning that means the list was reordered or grown
      *    in the middle, and the next migrate() would apply the missing one out
      *    of order.
      **/
    private void _checkAppliedIntegrity(ref AppliedMigration[] applied) {
        auto set = _appliedSet(applied);

        int highest = 0;
        foreach (a; applied) {
            if (a.version_ < 1 || a.version_ > cast(int)Migrations.length)
                throw new MigrationError(format!(
                    "Namespace '%s' has migration v%d applied, but the compiled " ~
                    "list only defines %d migration(s). The database was migrated " ~
                    "by a newer build — upgrade this binary before running again."
                )(_namespace, a.version_, cast(int)Migrations.length));
            if (a.version_ > highest) highest = a.version_;
        }

        foreach (v; 1 .. highest + 1)
            if (v !in set)
                throw new MigrationError(format!(
                    "Namespace '%s' is missing migration v%d while v%d is applied. " ~
                    "Migration versions are list positions, so this means the list " ~
                    "was reordered or extended in the middle; applying v%d now " ~
                    "would run it out of order."
                )(_namespace, v, highest, v));
    }

    private void _validateChecksums(ref AppliedMigration[] applied) {
        string[int] stored;
        foreach (a; applied) stored[a.version_] = a.checksum;

        static foreach (i, M; Migrations) {{
            enum ver = cast(int)(i + 1);
            enum cs  = _migrationChecksum!M();
            static if (cs.length) {
                if (auto p = ver in stored) {
                    // An empty stored value means the row predates the migration
                    // declaring a checksum — nothing to compare against.
                    if (p.length && *p != cs)
                        throw new MigrationError(format!(
                            "Migration %s (v%d) checksum mismatch: stored=%s computed=%s. " ~
                            "The migration changed after it was applied."
                        )(_migrationName!M(), ver, *p, cs));
                }
            }
        }}
    }
}

private bool[int] _appliedSet(ref AppliedMigration[] applied) {
    bool[int] set;
    foreach (a; applied) set[a.version_] = true;
    return set;
}

private string _migrationDesc(M)() {
    static if (__traits(hasMember, M, "description"))
        return M.description;
    else
        return __traits(identifier, M);
}

private string _migrationName(M)() {
    return __traits(fullyQualifiedName, M);
}

/** Content checksum for a migration, or "" when it declares none.
  *
  * Opt-in by design. D exposes no way to read a function body, so the SQL run by
  * `up(ref Transaction)` cannot be hashed automatically — a migration that wants
  * drift detection declares `enum checksum = "..."` (a hash or version tag of its
  * own SQL) and peque pins that value.
  *
  * Deliberately NOT derived from the fully-qualified name or the description, as
  * an earlier version was: that combination failed in both directions. Renaming a
  * module or struct, or editing a description, is a harmless change that bricked
  * every deployed database with a spurious mismatch, while editing the actual SQL
  * — the thing worth catching — went undetected.
  **/
private string _migrationChecksum(M)() {
    static if (__traits(hasMember, M, "checksum"))
        return M.checksum;
    else
        return "";
}

// FNV-1a 64-bit hash of "peque:" ~ namespace → PostgreSQL bigint advisory key.
// The prefix keeps peque's lock space distinct: advisory keys are global to the
// database, so an unrelated tool hashing the same bare namespace string would
// otherwise serialize against peque's migrations.
private long _advisoryKey(string ns) {
    ulong h = 14695981039346656037UL;
    foreach (c; "peque:" ~ ns) {
        h ^= cast(ubyte)c;
        h *= 1099511628211UL;
    }
    return cast(long)h;
}
