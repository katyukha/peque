/** ON CONFLICT actions and conflict targets for `insert!`.
  *
  * `INSERT … ON CONFLICT <target> <action>` has two independent choices, and
  * both are made at compile time:
  *
  * ---
  * repo.insert!(OnConflict.doNothing)(rec);                            // Nullable!M
  * repo.insert!(OnConflict.doNothing, Target.columns!("email"))(rec);  // Nullable!M
  * repo.insert!(OnConflict.doUpdate,  Target.columns!("email"))(rec);  // M
  * ---
  *
  * The action decides the return type, which is why it is a template argument
  * rather than a runtime flag: DO NOTHING yields no row when a conflicting row
  * already exists, so it must return `Nullable!M`, while DO UPDATE always
  * yields one. A runtime parameter would force `Nullable!M` on every insert.
  *
  * `Target.columns!` takes **D field names**, like `upsert!` and `where!` — not
  * SQL column names.
  **/
module peque.orm.conflict;


/// What to do when the insert conflicts with an existing row.
enum OnConflict {
    /// Leave the existing row alone. Yields no row, hence Nullable!M.
    doNothing,
    /// Overwrite the non-key columns from the values being inserted.
    doUpdate,
}


/// No conflict target: any conflict counts. Only valid with `doNothing` —
/// PostgreSQL requires a target to know which columns DO UPDATE may set.
struct TargetNone {}

/// Conflict on the unique index or constraint over these D fields.
struct TargetColumns(fields...) {
    static foreach (f; fields)
        static assert(is(typeof(f) == string),
            "Target.columns! takes D field names as string literals, got: " ~
            typeof(f).stringof);
    enum string[] _targetFields = [fields];
}

/// Conflict on a named constraint — `ON CONFLICT ON CONSTRAINT "name"`.
struct TargetConstraint(string name) {
    enum string _targetConstraint = name;
}

/** Namespace for the conflict targets, so the call site reads as one phrase.
  *
  * `Target.none` is the default, so `insert!(OnConflict.doNothing)(rec)` needs
  * no second argument.
  **/
struct Target {
    /// Conflict on the unique index over these D fields.
    alias columns(fields...) = TargetColumns!fields;
    /// Conflict on a named constraint.
    alias constraint(string name) = TargetConstraint!name;
    /// Any conflict at all.
    alias none = TargetNone;
}
