module peque.migrate.migrator;

private import std.format: format;
private import peque.connection: Connection;
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

struct Migrator(Migrations...)
if (Migrations.length > 0) {
    private Connection* _conn;
    private string      _namespace;

    this(Connection* conn, string namespace) {
        _conn      = conn;
        _namespace = namespace;
    }

    // Apply all pending migrations. Each migration runs in its own transaction.
    // Session-level advisory lock prevents races when multiple instances start at once.
    void migrate() {
        ensureVersionTable(*_conn);
        auto applied = loadApplied(*_conn, _namespace);

        _validateChecksums(applied);

        if (_pendingCount(applied) == 0) return;

        immutable lockKey = _advisoryKey(_namespace);
        _conn.execParams("SELECT pg_advisory_lock($1::bigint)", lockKey);
        scope(exit) _conn.execParams("SELECT pg_advisory_unlock($1::bigint)", lockKey);

        // Re-load after acquiring lock — another instance may have migrated.
        applied = loadApplied(*_conn, _namespace);
        _validateChecksums(applied);

        auto appliedSet = _appliedSet(applied);

        static foreach (i, M; Migrations) {{
            enum ver = cast(int)(i + 1);
            if (ver !in appliedSet) {
                _conn.transaction((ref _tx) {
                    M m;
                    m.up(*_conn);
                    recordMigration(
                        *_conn, _namespace, ver,
                        _migrationDesc!M(),
                        _migrationChecksum!M(),
                    );
                });
            }
        }}
    }

    // Return applied/pending status for every migration in the list.
    MigrationStatus[] status() {
        ensureVersionTable(*_conn);
        auto applied = loadApplied(*_conn, _namespace);

        // Build lookup maps in one pass.
        bool[int]   appliedSet;
        string[int] appliedAt;
        foreach (a; applied) {
            appliedSet[a.version_] = true;
            appliedAt[a.version_]  = a.appliedAt;
        }

        MigrationStatus[] result;
        static foreach (i, M; Migrations) {{
            enum ver = cast(int)(i + 1);
            bool   ok   = (ver in appliedSet) !is null;
            string when = ok ? appliedAt[ver] : "";
            result ~= MigrationStatus(ver, _migrationDesc!M(), ok, when);
        }}
        return result;
    }

    // Roll back the last n applied migrations (reverse order). Requires down().
    void rollback(int n = 1) {
        if (n <= 0) return;
        ensureVersionTable(*_conn);
        auto applied = loadApplied(*_conn, _namespace);
        if (applied.length == 0) return;

        immutable lockKey = _advisoryKey(_namespace);
        _conn.execParams("SELECT pg_advisory_lock($1::bigint)", lockKey);
        scope(exit) _conn.execParams("SELECT pg_advisory_unlock($1::bigint)", lockKey);

        applied = loadApplied(*_conn, _namespace);

        int rolled = 0;
        foreach_reverse (a; applied) {
            if (rolled >= n) break;
            immutable ver = a.version_;
            bool handled = false;
            static foreach (i, M; Migrations) {{
                if (!handled && cast(int)(i + 1) == ver) {
                    handled = true;
                    static if (__traits(hasMember, M, "down")) {
                        _conn.transaction((ref _tx) {
                            M m;
                            m.down(*_conn);
                            removeMigration(*_conn, _namespace, ver);
                        });
                    } else {
                        throw new MigrationError(format!(
                            "Migration %s (v%d) has no down() — cannot rollback"
                        )(_migrationName!M(), ver));
                    }
                }
            }}
            rolled++;
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private void _validateChecksums(ref AppliedMigration[] applied) {
        // Build checksum map in one pass, then validate each known migration.
        string[int] stored;
        foreach (a; applied) stored[a.version_] = a.checksum;

        static foreach (i, M; Migrations) {{
            enum ver = cast(int)(i + 1);
            if (auto p = ver in stored) {
                immutable cs = _migrationChecksum!M();
                if (*p != cs)
                    throw new MigrationError(format!(
                        "Migration %s (v%d) checksum mismatch: stored=%s computed=%s"
                    )(_migrationName!M(), ver, *p, cs));
            }
        }}
    }

    private int _pendingCount(ref AppliedMigration[] applied) {
        auto set = _appliedSet(applied);
        int count = 0;
        static foreach (i, M; Migrations)
            if (cast(int)(i + 1) !in set) count++;
        return count;
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

// SHA-256 of "<fqn>|<description>" — stable identity check for edited migrations.
private string _migrationChecksum(M)() {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    immutable input = __traits(fullyQualifiedName, M) ~ "|" ~ _migrationDesc!M();
    return toHexString(sha256Of(input)).idup;
}

// FNV-1a 64-bit hash of namespace → PostgreSQL bigint advisory lock key.
private long _advisoryKey(string ns) {
    ulong h = 14695981039346656037UL;
    foreach (c; ns) {
        h ^= cast(ubyte)c;
        h *= 1099511628211UL;
    }
    return cast(long)h;
}
