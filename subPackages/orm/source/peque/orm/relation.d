/** Writing a @many2many relation: the links of one parent row.
  *
  * A repository hands out a `Links` handle per parent and relation:
  * ---
  * auto l = groups.links!"permissions"(group.id);
  * l.add([3, 5]);                   // rows really inserted
  * l.remove([5]);                   // rows really deleted
  * l.clear();                       // every link of this parent
  * auto change = l.set([3, 8]);     // added: [8], removed: [5]
  *
  * // Bounded: only rows the universe contains can be linked or unlinked.
  * auto mine = tags.query().where!"projectId"(pid).asSubquery!"id"();
  * l.within(mine).set(ids);
  * ---
  *
  * `add` and `remove` are idempotent and commutative, so two callers racing on
  * one parent converge to the union of their intentions. `set` is two
  * statements — remove everything outside `ids`, then add `ids` — and is
  * atomic only inside a Transaction; two concurrent `set`s on one parent can
  * leave a mix of both lists (no duplicates, no dangling links). A caller who
  * needs more runs it under IsolationLevel.serializable and retries on
  * isRetriable().
  **/
module peque.orm.relation;

private import std.conv: to;
private import std.traits: TemplateOf;
private import std.typecons: Nullable, nullable;

private import peque.converter: PGValue, convertToPG;
private import peque.model: uniqueTogether, uniqueIndexTogether;
private import peque.query_context: isQueryContext;
private import peque.result: Result;
private import peque.orm.predicate: _shiftParams;
private import peque.orm.sql: _M2M, _sqlIdent, ormTableName, ormPkColName,
    ormPkFieldName;
private import peque.orm.subquery: SubQuery;


/** What a `Links.set` call changed: the target keys it linked and unlinked.
  * A key already linked and kept, or absent and left absent, is in neither.
  **/
struct RelationChange(Pk) {
    Pk[] added;
    Pk[] removed;

    /// True when anything was linked or unlinked.
    bool changed() const pure nothrow @safe @nogc {
        return added.length > 0 || removed.length > 0;
    }
}


// True when JM declares a unique constraint or unique index over exactly the
// two given D fields, in either order.
private template _junctionIsUnique(JM, string a, string b) {
    private static bool _pair(string[] fields) {
        return fields.length == 2 &&
            ((fields[0] == a && fields[1] == b) || (fields[0] == b && fields[1] == a));
    }
    private template _ofTemplate(alias uda, alias Tpl) {
        static if (is(uda))
            enum bool _ofTemplate = __traits(compiles, TemplateOf!uda) &&
                                    __traits(isSame, TemplateOf!uda, Tpl);
        else
            enum bool _ofTemplate = __traits(compiles, TemplateOf!(typeof(uda))) &&
                                    __traits(isSame, TemplateOf!(typeof(uda)), Tpl);
    }
    enum bool _junctionIsUnique = () {
        bool found = false;
        static foreach (uda; __traits(getAttributes, JM)) {{
            static if (_ofTemplate!(uda, uniqueTogether) ||
                       _ofTemplate!(uda, uniqueIndexTogether)) {
                static if (is(uda)) {
                    if (_pair(uda.fields)) found = true;
                } else {
                    if (_pair(typeof(uda).fields)) found = true;
                }
            }
        }}
        return found;
    }();
}


/** The links of one parent row on one @many2many relation.
  *
  * Obtained from a repository's `links!"field"(parentId)`; carries the same
  * borrowed `Ctx*` as the repository, so it is bounded by the same scope.
  *
  * Every operation touches only this parent's rows of the junction. A target
  * id that names no row, or a row outside `within`, is ignored rather than an
  * error: an option deleted between rendering a form and submitting it must
  * not fail the save. Duplicates in `ids` count once.
  **/
struct Links(M, string relField, Ctx)
if (isQueryContext!Ctx) {
    private alias Rel = _M2M!(M, relField);

    /// The related model.
    alias Target = Rel.Target;
    /// This model's primary-key type.
    alias ParentKey = typeof(__traits(getMember, M.init, ormPkFieldName!M()));
    /// The target model's primary-key type — the element type of every `ids`.
    alias TargetKey = typeof(__traits(getMember, Target.init, ormPkFieldName!Target()));

    // ON CONFLICT DO NOTHING only guards a concurrent insert of the same pair
    // when the junction is unique on it. A managed junction gets a composite
    // primary key; a junction model has to say so itself.
    static if (!is(Rel.JunctionModel == void))
        static assert(_junctionIsUnique!(Rel.JunctionModel, Rel.selfField, Rel.targetField),
            "links!\"" ~ relField ~ "\" on " ~ M.stringof ~ ": junction model " ~
            Rel.JunctionModel.stringof ~ " needs @uniqueTogether!(\"" ~
            Rel.selfField ~ "\", \"" ~ Rel.targetField ~ "\") (or " ~
            "@uniqueIndexTogether) — without it a concurrent save can duplicate " ~
            "a link.");

    private enum _jt  = _sqlIdent(Rel.table);
    private enum _sk  = _sqlIdent(Rel.selfCol);
    private enum _tk  = _sqlIdent(Rel.targetCol);
    private enum _pt  = ormTableName!M;
    private enum _ppk = ormPkColName!M();
    private enum _tt  = ormTableName!Target;
    private enum _tpk = ormPkColName!Target();

    private Ctx*      _ctx;
    private ParentKey _parent;
    private Nullable!(SubQuery!TargetKey) _within;

    @disable this();

    this(Ctx* ctx, ParentKey parent) pure nothrow @nogc @safe {
        _ctx    = ctx;
        _parent = parent;
    }

    /** Bound every operation to the target rows `universe` selects.
      *
      * A target outside it is neither linked nor unlinked — not even by `set`
      * or `clear`. A form cannot show a link its user is not allowed to see,
      * so an id missing from its submission is one that could never be
      * ticked, not one that was unticked.
      **/
    Links within(SubQuery!TargetKey universe) {
        auto l = this;
        l._within = nullable(universe);
        return l;
    }

    /// Link `ids`. Returns how many rows were inserted.
    long add(const(TargetKey)[] ids) {
        if (ids.length == 0) return 0;
        PGValue[] params;
        auto cond = _anyOf("t." ~ _tpk, ids, params);
        return _insert(cond, params, false).cmdTuples();
    }

    /// Link every target `ids` selects, without the keys leaving the server.
    long add(SubQuery!TargetKey ids) {
        PGValue[] params;
        auto cond = _inSub("t." ~ _tpk, ids, params);
        return _insert(cond, params, false).cmdTuples();
    }

    /// Unlink `ids`. Returns how many rows were deleted.
    long remove(const(TargetKey)[] ids) {
        if (ids.length == 0) return 0;
        PGValue[] params;
        auto cond = _anyOf(_tk, ids, params);
        return _delete(cond, params, false).cmdTuples();
    }

    /// Unlink every target `ids` selects.
    long remove(SubQuery!TargetKey ids) {
        PGValue[] params;
        auto cond = _inSub(_tk, ids, params);
        return _delete(cond, params, false).cmdTuples();
    }

    /// Unlink everything (inside `within`, when bounded). Returns the row count.
    long clear() {
        PGValue[] params;
        return _delete("", params, false).cmdTuples();
    }

    /** Make the links exactly `ids` (inside `within`, when bounded).
      *
      * Two statements: unlink what `ids` lacks, then link what it adds. Each
      * uses RETURNING, so the result reports only rows really changed —
      * nothing for a key that was already linked, or already absent.
      **/
    RelationChange!TargetKey set(const(TargetKey)[] ids) {
        RelationChange!TargetKey change;

        PGValue[] delParams;
        auto keep = _anyOf(_tk, ids, delParams);
        change.removed = _keys(_delete("NOT (" ~ keep ~ ")", delParams, true));

        if (ids.length) {
            PGValue[] insParams;
            auto cond = _anyOf("t." ~ _tpk, ids, insParams);
            change.added = _keys(_insert(cond, insParams, true));
        }
        return change;
    }

    // -- SQL assembly -------------------------------------------------------
    //
    // $1 is always the parent key. Each predicate builder appends its own
    // parameters and numbers its placeholders from the current count, so the
    // pieces compose in any order.

    private static string _anyOf(string col, const(TargetKey)[] ids, ref PGValue[] params) {
        params ~= convertToPG(ids);
        return col ~ " = ANY($" ~ (params.length + 1).to!string ~ ")";
    }

    private static string _inSub(string col, SubQuery!TargetKey sub, ref PGValue[] params) {
        auto sql = col ~ " IN (" ~ _shiftParams(sub.sql, cast(int) params.length + 1) ~ ")";
        params ~= sub.params;
        return sql;
    }

    private string _withinPred(string col, ref PGValue[] params) {
        if (_within.isNull) return "";
        return " AND " ~ _inSub(col, _within.get, params);
    }

    private PGValue[] _withParent(PGValue[] params) {
        return convertToPG(_parent) ~ params;
    }

    // INSERT … SELECT from both model tables: an unknown target or parent
    // selects nothing instead of failing a foreign key. NOT EXISTS keeps the
    // affected rows an honest diff even on a junction with no unique
    // constraint; ON CONFLICT covers a concurrent insert of the same pair when
    // there is one. Keys come back only when asked for.
    private Result _insert(string cond, PGValue[] params, bool returning) {
        auto within = _withinPred("t." ~ _tpk, params);
        string sql =
            "INSERT INTO " ~ _jt ~ " (" ~ _sk ~ ", " ~ _tk ~ ")" ~
            " SELECT p." ~ _ppk ~ ", t." ~ _tpk ~
            " FROM " ~ _tt ~ " t, " ~ _pt ~ " p" ~
            " WHERE p." ~ _ppk ~ " = $1 AND " ~ cond ~ within ~
            " AND NOT EXISTS (SELECT 1 FROM " ~ _jt ~ " x" ~
            " WHERE x." ~ _sk ~ " = $1 AND x." ~ _tk ~ " = t." ~ _tpk ~ ")" ~
            " ON CONFLICT DO NOTHING" ~ (returning ? " RETURNING " ~ _tk : "");
        return _ctx.execParams(sql, _withParent(params));
    }

    private Result _delete(string cond, PGValue[] params, bool returning) {
        auto within = _withinPred(_tk, params);
        string sql =
            "DELETE FROM " ~ _jt ~ " WHERE " ~ _sk ~ " = $1" ~
            (cond.length ? " AND " ~ cond : "") ~ within ~
            (returning ? " RETURNING " ~ _tk : "");
        return _ctx.execParams(sql, _withParent(params));
    }

    private static TargetKey[] _keys(Result r) {
        TargetKey[] keys;
        keys.reserve(r.ntuples);
        foreach (i; 0 .. r.ntuples)
            keys ~= r.getRow(i)[0].as!TargetKey;
        return keys;
    }
}
