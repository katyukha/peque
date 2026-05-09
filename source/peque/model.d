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


/** Controls the ON DELETE behaviour of a @many2one FK column in generated DDL.
  *
  * Has no effect at query time — CRUD operations are unchanged.
  * Only affects the REFERENCES clause emitted by schemaSQL / modelDDL.
  *
  * OnDelete.noAction is the PostgreSQL default; no clause is emitted for it.
  * OnDelete.setNull requires the field type to be Nullable!T.
  **/
enum OnDelete {
    noAction,   /// PostgreSQL default (deferred RESTRICT); no clause emitted
    restrict,   /// ON DELETE RESTRICT
    cascade,    /// ON DELETE CASCADE
    setNull,    /// ON DELETE SET NULL  — field type must be Nullable!T
    setDefault, /// ON DELETE SET DEFAULT
}


/** Mark a field as a many-to-one (foreign key) relation.
  *
  * The field holds the integer FK value (always loaded as a real DB column).
  * Column name is derived by camelCase→snake_case of the field name unless
  * a @field("col") UDA is also present to override it.
  *
  * T        = the target model struct.
  * onDelete = ON DELETE behaviour in generated DDL (default: noAction).
  *
  * Example:
  * ---
  * @model("sale_order")
  * struct Order {
  *     @primaryKey                        int              id;
  *     @field                             string           name;
  *     @many2one!(Partner)                int              partnerId;
  *     @many2one!(User, OnDelete.cascade) int              userId;
  *     @related                           Nullable!Partner partner;
  * }
  * ---
  **/
struct many2one(T, OnDelete onDelete = OnDelete.noAction) {}


/** Mark a field as a one-to-many (inverse FK) relation.
  *
  * No DB column exists on this side. The array field is always empty at
  * hydration time; it is populated only when QuerySet.prefetch! is used.
  *
  * T            = the target model struct.
  * inverseField = D field name of the FK on T that points back to this model.
  *                Column name is resolved by camelToSnake(inverseField).
  *
  * Example:
  * ---
  * @model("res_partner")
  * struct Partner {
  *     @primaryKey                          int       id;
  *     @one2many!(Invoice, "partnerId")     Invoice[] invoices;
  * }
  * ---
  **/
struct one2many(T, string inverseField) {}


/** Mark a field as a many-to-many relation via a junction table.
  *
  * No DB column exists on this side. The array field is always empty at
  * hydration time; it is populated only when QuerySet.prefetch! is used.
  *
  * T             = the target model struct.
  * junctionTable = SQL name of the junction table.
  * selfKey       = column name in junction table pointing to this model's PK.
  * targetKey     = column name in junction table pointing to T's PK.
  *
  * Example:
  * ---
  * @model("res_partner")
  * struct Partner {
  *     @primaryKey                                              int    id;
  *     @many2many!(Tag, "partner_tag_rel", "partner_id", "tag_id")
  *     Tag[] tags;
  * }
  * ---
  **/
struct many2many(T, string junctionTable, string selfKey = "", string targetKey = "") {}


/** Mark a field as a populated relation object (not a DB column).
  *
  * Skipped by normal column hydration — left at its zero/init value.
  * Populated by QuerySet.joinOne! (for @many2one backing fields) or
  * QuerySet.prefetch! (for @one2many/@many2many fields).
  *
  * When a model has more than one @many2one pointing to the same target type,
  * each @related field must name its backing FK field explicitly so joinOne!
  * can emit the correct ON clause.
  *
  * Example — single FK (common case, fkField omitted):
  * ---
  * @many2one!(Partner)  int              partnerId;
  * @related             Nullable!Partner partner;
  * ---
  *
  * Example — two FKs to the same type (fkField required):
  * ---
  * @many2one!(Partner)          int              invoiceAddressId;
  * @related("invoiceAddressId") Nullable!Partner invoiceAddress;
  *
  * @many2one!(Partner)          int              deliveryAddressId;
  * @related("deliveryAddressId") Nullable!Partner deliveryAddress;
  * ---
  **/
struct related {
    string fkField = "";
}


/** Override the PostgreSQL column type used by schemaSQL / modelDDL.
  *
  * By default, schemaSQL maps D types to PostgreSQL types automatically
  * (int → INTEGER, string → TEXT, etc.).  Use @pgType to override for a
  * specific field when the default is wrong.
  *
  * The supplied string is used verbatim as the column type — no automatic
  * SERIAL substitution even on @primaryKey fields.
  *
  * Examples:
  * ---
  * @pgType("VARCHAR(255)")  string name;
  * @pgType("UUID")          string id;
  * @pgType("NUMERIC(10,2)") double price;
  * ---
  **/
struct pgType {
    string typeName;
    this(string t) @safe pure nothrow { typeName = t; }
}


/** Specify default sort order for findAll() and the base QuerySet.
  *
  * Applied on a model struct. CRUDMixin.findAll() appends ORDER BY when this
  * UDA is present and neither the host repository nor an explicit QuerySet
  * ordering overrides it.
  *
  * Single field (ascending implied):
  * ---
  * @defaultOrder!"name"
  * @model("res_partner")
  * struct Partner { ... }
  * ---
  *
  * Multiple fields with explicit direction:
  * ---
  * @defaultOrder!("date DESC", "id DESC")
  * @model("sale_order")
  * struct Order { ... }
  * ---
  *
  * Per-repository override: define `enum defaultOrder = "col ASC"` as a
  * manifest constant in your repository struct — it takes priority over
  * the model UDA.
  **/
struct defaultOrder(fields...) if (fields.length >= 1) {}


/** Check if a symbol has any @many2one!(T, ...) UDA attached (any T, any OnDelete).
  *
  * Used internally by the hydration and ORM layers to detect FK fields.
  **/
template hasMany2OneUDA(alias sym) {
    private template _isM2O(alias uda) {
        static if (is(uda))
            enum bool _isM2O = is(uda == many2one!(U, od), U, OnDelete od);
        else
            enum bool _isM2O = false;
    }
    import std.meta: anySatisfy;
    enum bool hasMany2OneUDA = anySatisfy!(_isM2O, __traits(getAttributes, sym));
}


// ---------------------------------------------------------------------------
// Schema Phase 2 — column and table constraint UDAs
// ---------------------------------------------------------------------------

/** Add a UNIQUE constraint to a column in the generated DDL. **/
struct unique {}

/** Add an inline CHECK constraint to a column in the generated DDL.
  *
  * Example:
  * ---
  * @check("price > 0")  double price;
  * ---
  **/
struct check {
    string expr;
    this(string e) @safe pure nothrow { expr = e; }
}

/** Add a DEFAULT clause to a column in the generated DDL.
  *
  * The expression is passed verbatim to PostgreSQL.
  *
  * Example:
  * ---
  * @pgDefault("now()")  SysTime createdAt;
  * @pgDefault("true")   bool    active;
  * ---
  **/
struct pgDefault {
    string expr;
    this(string e) @safe pure nothrow { expr = e; }
}

/** Force NOT NULL on a Nullable!T field in the generated DDL.
  *
  * Rarely needed — non-Nullable fields already get NOT NULL automatically.
  * Useful when a field is Nullable in D but has a DEFAULT in the DB so the
  * column itself should be NOT NULL.
  *
  * Example:
  * ---
  * @pgDefault("0") @pgNotNull  Nullable!int priority;
  * ---
  **/
struct pgNotNull {}

/** Table-level UNIQUE (col1, col2, ...) constraint. Applied on the model struct.
  *
  * cols are SQL column names (snake_case).
  *
  * Example:
  * ---
  * @uniqueTogether!("name", "tenant_id")
  * @model("res_partner")
  * struct Partner { ... }
  * ---
  **/
struct uniqueTogether(cols...) if (cols.length >= 2) {
    enum string[] columns = [cols];
}

/** Named table-level CHECK constraint. Applied on the model struct.
  *
  * Example:
  * ---
  * @checkConstraint("chk_price_positive", "price > 0")
  * @model("sale_order")
  * struct Order { ... }
  * ---
  **/
struct checkConstraint {
    string name;
    string expr;
    this(string n, string e) @safe pure nothrow { name = n; expr = e; }
}

/** Create a single-column btree index on this field in the generated DDL.
  *
  * An optional WHERE clause turns it into a partial index.
  *
  * Examples:
  * ---
  * @index                          string email;   // CREATE INDEX ON table (email)
  * @index(where: "active = true")  string email;   // CREATE INDEX … WHERE active = true
  * ---
  **/
struct index { string where = ""; }

/** Create a single-column unique btree index on this field in the generated DDL.
  *
  * Examples:
  * ---
  * @uniqueIndex                           string slug;
  * @uniqueIndex(where: "deleted_at IS NULL") string slug;
  * ---
  **/
struct uniqueIndex { string where = ""; }

/** Create a single-column GIN index on this field in the generated DDL.
  *
  * GIN indexes are suited for array columns, tsvector full-text search, and JSONB.
  * Emits: CREATE INDEX … USING gin (col) [WHERE cond]
  *
  * Example:
  * ---
  * @ginIndex  string[] tags;
  * ---
  **/
struct ginIndex { string where = ""; }

/** Create a single-column GiST index on this field in the generated DDL.
  *
  * GiST indexes suit geometric types, range types, and full-text search.
  * Emits: CREATE INDEX … USING gist (col) [WHERE cond]
  **/
struct gistIndex { string where = ""; }

/** Create a single-column Hash index on this field in the generated DDL.
  *
  * Hash indexes only support equality lookups — no range scans.
  * Emits: CREATE INDEX … USING hash (col) [WHERE cond]
  **/
struct hashIndex { string where = ""; }

/** Create a multi-column btree index. Applied on the model struct.
  *
  * cols are SQL column names (snake_case).
  * An optional WHERE clause turns it into a partial index.
  *
  * Examples:
  * ---
  * @indexTogether!("partner_id", "status")
  * @model("sale_order")
  * struct Order { ... }
  *
  * // Partial multi-column index:
  * @(indexTogether!("partner_id", "status")(where: "status != 'closed'"))
  * @model("sale_order")
  * struct Order { ... }
  * ---
  **/
struct indexTogether(cols...) if (cols.length >= 2) {
    enum string[] columns = [cols];
    string where = "";
}

/** Create a multi-column unique index. Applied on the model struct.
  *
  * Unlike @uniqueTogether (which is a table-level UNIQUE constraint inside
  * CREATE TABLE), this emits a standalone CREATE UNIQUE INDEX statement,
  * allowing an optional WHERE partial-index clause.
  *
  * cols are SQL column names (snake_case).
  *
  * Examples:
  * ---
  * @uniqueIndexTogether!("tenant_id", "email")
  * @model("users")
  * struct User { ... }
  *
  * // Partial unique index:
  * @(uniqueIndexTogether!("tenant_id", "email")(where: "deleted_at IS NULL"))
  * @model("users")
  * struct User { ... }
  * ---
  **/
struct uniqueIndexTogether(cols...) if (cols.length >= 2) {
    enum string[] columns = [cols];
    string where = "";
}
