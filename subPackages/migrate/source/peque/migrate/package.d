/** peque:migrate — compile-time D-based database migration runner.
  *
  * Migrations are plain D structs compiled into the application binary.
  * Version = 1-based position in MigrationList!() — never reorder.
  *
  * Quick start:
  * ---
  * import peque;
  * import peque.migrate;
  *
  * struct V1_Init {
  *     enum description = "create users table";
  *     void up(ref Connection conn) {
  *         conn.exec(`CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL)`);
  *     }
  *     void down(ref Connection conn) {
  *         conn.exec(`DROP TABLE users`);
  *     }
  * }
  *
  * struct V2_AddEmail {
  *     enum description = "add email column";
  *     void up(ref Connection conn) {
  *         conn.exec(`ALTER TABLE users ADD COLUMN email text NOT NULL DEFAULT ''`);
  *     }
  *     void down(ref Connection conn) {
  *         conn.exec(`ALTER TABLE users DROP COLUMN email`);
  *     }
  * }
  *
  * alias AppMigrations = MigrationList!(V1_Init, V2_AddEmail);
  *
  * // On startup:
  * auto m = Migrator!(AppMigrations)(&conn, "myapp");
  * m.migrate();      // apply all pending; advisory-locked; each in its own transaction
  * m.status();       // returns MigrationStatus[] — applied vs pending
  * m.rollback(1);    // roll back last 1 applied (requires down() — clear error if absent)
  * ---
  *
  * Integration with peque:orm — V1 can reuse DDL generation:
  * ---
  * import peque.orm: schemaSQL;
  *
  * struct V1_InitSchema {
  *     enum description = "create all tables";
  *     void up(ref Connection conn) {
  *         conn.exec(schemaSQL!AppRegistry());
  *     }
  * }
  * ---
  *
  * Multi-module: use distinct namespaces — version sequences are independent.
  * ---
  * Migrator!(LibMigrations)(&conn, "lib_core").migrate();
  * Migrator!(AppMigrations)(&conn, "myapp").migrate();
  * ---
  **/
module peque.migrate;

public import peque.migrate.migrator: MigrationList, MigrationError, Migrator, MigrationStatus;
