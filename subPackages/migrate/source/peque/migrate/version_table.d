module peque.migrate.version_table;

private import peque.connection: Connection;

struct AppliedMigration {
    string namespace;
    int    version_;
    string description;
    string appliedAt;
    string checksum;
}

void ensureVersionTable(ref Connection conn) {
    conn.exec(`
        CREATE TABLE IF NOT EXISTS schema_versions (
            namespace    TEXT        NOT NULL DEFAULT 'default',
            version      INTEGER     NOT NULL,
            description  TEXT        NOT NULL,
            applied_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
            checksum     TEXT        NOT NULL,
            PRIMARY KEY (namespace, version)
        )
    `);
}

AppliedMigration[] loadApplied(ref Connection conn, string namespace) {
    auto result = conn.execParams(
        `SELECT version, description, applied_at::text, checksum
         FROM schema_versions
         WHERE namespace = $1
         ORDER BY version ASC`,
        namespace,
    );
    AppliedMigration[] rows;
    foreach (row; result) {
        rows ~= AppliedMigration(
            namespace,
            row["version"].get!int,
            row["description"].get!string,
            row["applied_at"].get!string,
            row["checksum"].get!string,
        );
    }
    return rows;
}

void recordMigration(
    ref Connection conn,
    string namespace,
    int    ver,
    string description,
    string checksum,
) {
    conn.execParams(
        `INSERT INTO schema_versions (namespace, version, description, checksum)
         VALUES ($1, $2, $3, $4)`,
        namespace, ver, description, checksum,
    );
}

void removeMigration(ref Connection conn, string namespace, int ver) {
    conn.execParams(
        `DELETE FROM schema_versions WHERE namespace = $1 AND version = $2`,
        namespace, ver,
    );
}
