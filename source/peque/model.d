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
  * The table name is optional when the struct is only used for hydration; the
  * query builder needs it to generate FROM clauses.
  **/
struct model {
    string tableName = "";

    this(string name) @safe pure nothrow { tableName = name; }
}


/** Map a struct field to a database column.
  *
  * Without argument: the column is named exactly like the D member. peque
  * quotes every identifier, so nothing is derived or case-converted.
  *
  * With a string argument: use that string as the exact column name — this is
  * how you address a column whose name differs from the member's.
  *
  * Examples:
  * ---
  * @field                string name;          // column: "name"
  * @field                string emailAddress;  // column: "emailAddress"
  * @field("email_addr")  string email;         // column: "email_addr"
  * ---
  *
  * `related:` names a value reached through a relation instead of a column on
  * this table. It is read by the ORM's `select!DTO` and is only meaningful on a
  * projection struct — a model's columns all live on its own table:
  * ---
  * @autoHydrate
  * struct OrderSummary {
  *     int    id;
  *     @field(related: "partner.name") string partnerName;
  * }
  * ---
  *
  * The two are mutually exclusive: a member is either a column on this table or
  * a value from a related one.
  **/
struct field {
    string columnName = "";
    string related    = "";
}


/** Mark a field as the primary key.
  *
  * Behaves like @field for column-name resolution: the member name is the
  * column name unless combined with @field("col").
  *
  * Example:
  * ---
  * @primaryKey              int id;         // column: "id"
  * @primaryKey @field("pk") int id;         // column: "pk"
  * ---
  **/
struct primaryKey {}


/** Enable convention-based struct hydration without explicit @model or @field UDAs.
  *
  * All public fields are hydrated from columns of exactly the same name.
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
  * The column is named exactly like the D member unless a @field("col") UDA is
  * also present to override it.
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
  *                Its column name honours @field on that member.
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
  * Each argument is normalized to an order term:
  *  - a raw SQL `string` — emitted verbatim (you write the real column/SQL);
  *  - an `F` builder (from `peque.orm`) — a field reference resolved against
  *    the model (camelCase → column, implicit LEFT JOIN for join paths), with
  *    optional `.desc` / `.nullsLast`.
  *
  * Raw SQL string (ascending implied):
  * ---
  * @defaultOrder!"name"
  * @model("res_partner")
  * struct Partner { ... }
  * ---
  *
  * Multiple raw fields with explicit direction:
  * ---
  * @defaultOrder!("date DESC", "id DESC")
  * @model("sale_order")
  * struct Order { ... }
  * ---
  *
  * Typed field references (resolved like query().orderBy):
  * ---
  * @defaultOrder!(F!"createdAt".desc)              // → created_at DESC
  * @defaultOrder!(F!"partner.name", F!"id".desc)   // join path + direction
  * @model("sale_order")
  * struct Order { ... }
  * ---
  *
  * Per-repository override: define `enum defaultOrder = "col ASC"` as a
  * manifest constant in your repository struct — it takes priority over
  * the model UDA.
  **/
struct defaultOrder(fields...) if (fields.length >= 1) {}


/** Normalize a single UDA to its `many2one!(T, od)` type, or `void`.
  *
  * A UDA may be attached in either of two forms, and both must be recognised:
  * `@many2one!(Partner)` (the type itself) and `@many2one!(Partner)()` (an
  * instance) — the latter is a natural thing to write given `@field()` and
  * `@index(...)` are instances. Feeding both through this template keeps the
  * detector (hasMany2OneUDA) and every target-type extractor in agreement; a
  * site that pattern-matched only the type form would silently skip the
  * instance form and drop the FK from hydration, DDL, or join resolution.
  *
  * Non-many2one UDAs (and symbols with no `typeof`, e.g. a bare template name)
  * normalize to `void`, which never matches a `many2one!(T, od)` pattern.
  **/
template many2oneUDAType(alias uda) {
    static if (is(uda))
        alias many2oneUDAType = uda;
    else static if (__traits(compiles, typeof(uda)))
        alias many2oneUDAType = typeof(uda);
    else
        alias many2oneUDAType = void;
}

/** Check if a symbol has any @many2one!(T, ...) UDA attached (any T, any OnDelete).
  *
  * Accepts both the type form (`@many2one!(Partner)`) and the instance form
  * (`@many2one!(Partner)()`). Used internally by the hydration and ORM layers
  * to detect FK fields.
  **/
template hasMany2OneUDA(alias sym) {
    private template _isM2O(alias uda) {
        enum bool _isM2O =
            is(many2oneUDAType!uda == many2one!(U, od), U, OnDelete od);
    }
    import std.meta: anySatisfy;
    enum bool hasMany2OneUDA = anySatisfy!(_isM2O, __traits(getAttributes, sym));
}


// ---------------------------------------------------------------------------
// Column and table constraint UDAs
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
  * This is a DATABASE-LEVEL declaration and nothing more. The expression is
  * passed verbatim to PostgreSQL and describes the column; it does not take
  * part in INSERT.
  *
  * peque's insert always names every column and binds the D field's value, so
  * a DEFAULT here never fires on the peque path. It applies to rows written by
  * other applications, to a later ALTER TABLE ... ADD COLUMN, and it documents
  * the column in the schema.
  *
  * The trap this makes explicit:
  * ---
  * @field @pgDefault("now()") SysTime createdAt;   // does NOT give you now()
  * ---
  * peque sends SysTime.init, so the row gets year 1 — not the server's clock.
  * Set the value in D instead:
  * ---
  * @field SysTime createdAt;
  * void applyDefaults() { createdAt = Clock.currTime; }
  * ---
  *
  * Where a default belongs:
  *   compile-time constant  → a D field initialiser (`bool active = true;`),
  *                            which peque sends on every insert
  *   computed per insert    → applyDefaults()
  *   database-level only    → @pgDefault
  *
  * Example:
  * ---
  * @pgDefault("now()")  SysTime createdAt;   // for other writers, not peque
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
  * cols are SQL column names.
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
  * The field must also be a column (@field / @primaryKey / @many2one) — an
  * index UDA on a non-column field is a compile error rather than a silently
  * missing index.
  *
  * Use name: to give the index an explicit name; two indexes that would
  * otherwise derive the same name are rejected at compile time.
  *
  * Examples:
  * ---
  * @field @index                         string email;  // CREATE INDEX ON table (email)
  * @field @index(where: "active = true") string email;  // partial index
  * @field @index(where: "a = 1")
  *        @index(where: "b = 2", name: "idx_t_email_b") string email;
  * ---
  **/
struct index { string where = ""; string name = ""; }

/** Create a single-column unique btree index on this field in the generated DDL.
  *
  * Examples:
  * ---
  * @field @uniqueIndex                             string slug;
  * @field @uniqueIndex(where: "deleted_at IS NULL") string slug;
  * ---
  **/
struct uniqueIndex { string where = ""; string name = ""; }

/** Create a single-column GIN index on this field in the generated DDL.
  *
  * GIN indexes are suited for array columns, tsvector full-text search, and JSONB.
  * Emits: CREATE INDEX … USING gin (col) [WHERE cond]
  *
  * The field must also carry @field to be a column. Array columns additionally
  * need an explicit @pgType, since D slices have no default PostgreSQL mapping.
  *
  * Example:
  * ---
  * @field @pgType("TEXT[]") @ginIndex string[] tags;
  * ---
  **/
struct ginIndex { string where = ""; string name = ""; }

/** Create a single-column GiST index on this field in the generated DDL.
  *
  * GiST indexes suit geometric types, range types, and full-text search.
  * Emits: CREATE INDEX … USING gist (col) [WHERE cond]
  **/
struct gistIndex { string where = ""; string name = ""; }

/** Create a single-column Hash index on this field in the generated DDL.
  *
  * Hash indexes only support equality lookups — no range scans.
  * Emits: CREATE INDEX … USING hash (col) [WHERE cond]
  **/
struct hashIndex { string where = ""; string name = ""; }

/** Create a multi-column btree index. Applied on the model struct.
  *
  * cols are SQL column names.
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
    string name  = "";
}

/** Create a multi-column unique index. Applied on the model struct.
  *
  * Unlike @uniqueTogether (which is a table-level UNIQUE constraint inside
  * CREATE TABLE), this emits a standalone CREATE UNIQUE INDEX statement,
  * allowing an optional WHERE partial-index clause.
  *
  * cols are SQL column names.
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
    string name  = "";
}
