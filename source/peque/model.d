/** UDA definitions for peque's struct-mapping layer.
  *
  * Import this module (or the top-level `peque` package) to annotate model structs.
  *
  * Typical use:
  * ---
  * import peque;
  *
  * @model("res_partner")
  * struct Partner {
  *     @primaryKey             int    id;
  *     @field                  string name;
  *     @field("email_address") string email;
  *     int                     age;    // not annotated → ignored by @model hydration
  * }
  * ---
  **/
module peque.model;


/** Mark a struct as a database model.
  *
  * Enables struct hydration via ResultRow.as!T / Result.as!(T[]).
  *
  * Only fields annotated with @field or @primaryKey are hydrated.
  * Unannotated fields are left at their zero/init value.
  *
  * The table name argument is optional for Phase 4a (hydration-only).
  * It will be used by the query builder (Phase 4c/4d) to generate FROM clauses.
  **/
struct model {
    string tableName = "";

    this(string name) @safe pure nothrow { tableName = name; }
}


/** Map a struct field to a database column.
  *
  * Without argument: column name is derived from the field name by
  * camelCase→snake_case conversion (e.g. `emailAddress` → `email_address`).
  *
  * With a string argument: use that string as the exact column name.
  *
  * Examples:
  * ---
  * @field              string name;          // column: "name"
  * @field              string emailAddress;  // column: "email_address"
  * @field("email_addr") string email;        // column: "email_addr"
  * ---
  **/
struct field {
    string columnName = "";

    this(string colName) @safe pure nothrow { columnName = colName; }
}


/** Mark a field as the primary key.
  *
  * Behaves like @field for column-name resolution (camelCase→snake_case unless
  * combined with @field("col")).
  *
  * Example:
  * ---
  * @primaryKey             int id;          // column: "id"
  * @primaryKey @field("pk") int id;          // column: "pk"
  * ---
  **/
struct primaryKey {}


/** Enable convention-based struct hydration without explicit @model or @field UDAs.
  *
  * All public fields are hydrated from same-named columns (camelCase→snake_case).
  * Fields whose columns are absent from the result are silently skipped — they
  * remain at their zero/init value.
  *
  * Useful for lightweight DTOs where you SELECT only a subset of columns.
  *
  * Example:
  * ---
  * @autoHydrate
  * struct PartnerSummary {
  *     int    id;
  *     string name;
  *     // any extra columns in the result are ignored; missing ones skipped
  * }
  * ---
  **/
struct autoHydrate {}
